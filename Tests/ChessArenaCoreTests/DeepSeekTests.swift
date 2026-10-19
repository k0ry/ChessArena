import Foundation
import XCTest
@testable import ChessArenaCore

final class DeepSeekTests: XCTestCase {
    func testBudgetPersistsAndLegacyConfigurationUsesOriginalDefault() throws {
        var config = PlayerConfiguration(provider: .deepseek)
        config.maxOutputTokens = 32_768
        let restored = try JSONDecoder().decode(PlayerConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.maxOutputTokens, 32_768)
        XCTAssertEqual(restored.seat(side: .white, keys: ProviderKeys()).maxOutputTokens, 32_768)
        let legacy = try JSONDecoder().decode(PlayerConfiguration.self, from: Data(#"{"provider":"DeepSeek","model":"deepseek-v4-pro"}"#.utf8))
        XCTAssertNil(legacy.maxOutputTokens)
        var call = deepSeekCall(1)
        call.maxOutputTokens = restored.maxOutputTokens
        XCTAssertEqual(DeepSeekAPI.body(for: call)["max_tokens"] as? Int, 32_768)
        call.maxOutputTokens = legacy.maxOutputTokens
        XCTAssertEqual(DeepSeekAPI.body(for: call)["max_tokens"] as? Int, 16_384)
    }

    @MainActor
    func testLengthFromHTTPPausesGameAndPersistsSafeDiagnosticsWithoutScoring() async throws {
        let server = MiniHTTPServer(), seen = DeepSeekRequests()
        server.handler = { request in
            seen.append(request)
            return .init(status: 200, body: Data(#"{"choices":[{"finish_reason":"length","message":{"content":"{\"move\":\"e2e4\"}","reasoning_content":"PRIVATE_REASONING fixture-secret"}}],"usage":{"prompt_tokens":500,"completion_tokens":16384,"total_tokens":16884}}"#.utf8))
        }
        try server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var white = PlayerConfiguration(provider: .deepseek).seat(side: .white, keys: ProviderKeys(deepseek: "fixture-secret"))
        white.baseURL = localURL(server.port)
        let archive = MatchArchive(directory: directory, whiteName: "DeepSeek", blackName: "Gemini")
        let engine = MatchEngine(scene: BoardScene(), voice: ScriptedVoice(), transport: DeepSeekTransport(timeout: 3), archive: archive,
                                 white: white, black: Seat.defaultBlack(apiKey: ""), host: Seat.defaultWhite(apiKey: ""))
        let log = ModelLog(); engine.modelLog = log
        var series = MatchSeries(); let round = series.start()
        engine.onGameEnded = { end in _ = series.complete(round: round, result: end, position: engine.referee.position, now: 0) }
        try await engine.start(at: 0)
        for _ in 0..<200 { if engine.paused { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(engine.paused)
        XCTAssertNil(engine.retryAt)
        XCTAssertTrue(engine.pauseReason?.contains("обрезан") == true)
        XCTAssertNil(engine.referee.end)
        XCTAssertEqual(series.score.games, 0)
        XCTAssertNil(series.restartAt)
        XCTAssertEqual(engine.referee.position, .standard())
        XCTAssertEqual(engine.finalCards, 0)
        await engine.advance(to: 100_000)
        XCTAssertEqual(seen.values.count, 1)
        XCTAssertTrue(log.entries.first?.text.contains("finish_reason: length") == true)
        engine.stop(); try await engine.closeArchive()
        let diagnostics = try String(contentsOf: archive.diagnosticsURL, encoding: .utf8)
        XCTAssertTrue(diagnostics.contains("length"))
        XCTAssertTrue(diagnostics.contains("truncated"))
        XCTAssertTrue(diagnostics.contains("16384"))
        XCTAssertFalse(diagnostics.contains("PRIVATE_REASONING"))
        XCTAssertFalse(diagnostics.contains("fixture-secret"))
        XCTAssertTrue(try String(contentsOf: archive.pgnURL, encoding: .utf8).contains("[Result \"*\"]"))
        XCTAssertFalse(archive.journal.contains { $0.kind == "final" })
        XCTAssertNil(engine.gameMemory.advice(for: white))
    }

    func testIndependentSeatsKeysDefaultsAndHostSelection() throws {
        let keys = ProviderKeys(grok: "grok", chatGPT: "openai", anthropic: "anthropic", deepseek: " deepseek-key\n")
        let white = PlayerConfiguration(provider: .deepseek)
        var black = white
        black.model = "deepseek-flash"
        XCTAssertEqual(white.model, "deepseek-v4-pro")
        let seat = white.seat(side: .white, keys: keys)
        XCTAssertEqual(seat.apiKey, "deepseek-key")
        XCTAssertEqual(seat.completionsURL.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(seat.route, .deepseek)
        XCTAssertEqual(black.seat(side: .black, keys: keys).model, "deepseek-flash")
        XCTAssertEqual(keys.key(for: .grok), "grok")
        XCTAssertEqual(keys.key(for: .chatGPT), "openai")
        XCTAssertEqual(keys.key(for: .claude), "")
        XCTAssertEqual(NeuralProvider.allCases.filter(\.supportsHost), [.grok, .chatGPT, .claude])
    }

    @MainActor
    func testWireFormatsRoutingAndSafeLogs() async throws {
        let server = MiniHTTPServer(), seen = DeepSeekRequests()
        let key = "deepseek-fixture-key-123"
        let answer = #"{"move":"e2e4","taunt":"After you.","self_notes":"remember deepseek-fixture-key-123"}"#
        server.handler = { request in
            seen.append(request)
            return .init(status: 200, body: deepSeekEnvelope(answer, reasoning: "PRIVATE_REASONING"))
        }
        try server.start(); defer { server.stop() }
        let transport = ArenaChatTransport(connection: nil, api: RejectDeepSeekFallback(),
                                           deepseek: DeepSeekTransport(timeout: 3))
        var call = deepSeekCall(server.port, key: key)
        call.selfNotes = "OWN_NOTES"; call.gameAdvice = "OWN_ADVICE"
        let before = NetworkLog.shared.entries.count
        let text = try await transport.complete(call)
        XCTAssertEqual(ChatParser.moveIntent(from: text)?.move, "e2e4")
        XCTAssertFalse(text.contains(key))
        XCTAssertFalse(text.contains("PRIVATE_REASONING"))
        XCTAssertTrue(text.contains("[REDACTED]"))
        let json = try payload(XCTUnwrap(seen.values.first))
        XCTAssertEqual(seen.values.first?.path, "/chat/completions")
        XCTAssertEqual(seen.values.first?.headers["authorization"], "Bearer " + key)
        XCTAssertEqual(json["model"] as? String, ModelCatalog.deepSeekModel)
        XCTAssertEqual(json["max_tokens"] as? Int, 16_384)
        XCTAssertEqual(json["reasoning_effort"] as? String, "high")
        XCTAssertEqual(json["thinking"] as? [String: String], ["type": "enabled"])
        XCTAssertEqual(json["response_format"] as? [String: String], ["type": "json_object"])
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertNil(json["tools"])
        XCTAssertNil(json["temperature"])
        XCTAssertEqual(json["messages"] as? [[String: String]], [["role": "system", "content": call.system]] + call.inputMessages)
        call.responseFormat = .text
        _ = try await transport.complete(call)
        XCTAssertNil(try payload(XCTUnwrap(seen.values.last))["response_format"])
        XCTAssertEqual(transport.requestURL(for: call), call.url)
        XCTAssertGreaterThan(NetworkLog.shared.entries.count, before)
        let network = NetworkLog.shared.entries.prefix(2).map(\.text).joined()
        XCTAssertFalse(network.contains(key)); XCTAssertFalse(network.contains("PRIVATE_REASONING"))
        let log = ModelLog()
        let id = log.begin(call, context: "DeepSeek", endpoint: call.url)
        log.succeed(id, response: text, secrets: [key])
        XCTAssertFalse(log.entries[0].text.contains(key))
        XCTAssertFalse(log.entries[0].text.contains("PRIVATE_REASONING"))
    }

    func testRejectsIncompleteResponsesEvenWithValidJSON() throws {
        let valid = #"{"move":"e2e4"}"#
        XCTAssertEqual(try DeepSeekAPI.text(from: deepSeekEnvelope(valid)), valid)
        for finish in ["length", "tool_calls", "unknown"] {
            XCTAssertThrowsError(try DeepSeekAPI.text(from: deepSeekEnvelope(valid, finish: finish))) {
                XCTAssertEqual($0 as? ChatError, .response(finish == "length" ? .truncated : .schema))
            }
        }
        XCTAssertThrowsError(try DeepSeekAPI.text(from: deepSeekEnvelope(valid, finish: "content_filter"))) {
            XCTAssertEqual($0 as? ChatError, .refused)
        }
        for finish in ["aborted", "insufficient_system_resource"] {
            XCTAssertThrowsError(try DeepSeekAPI.text(from: deepSeekEnvelope(valid, finish: finish))) {
                XCTAssertEqual($0 as? ChatError, .transport)
            }
        }
        XCTAssertThrowsError(try DeepSeekAPI.text(from: deepSeekEnvelope("  \n"))) { XCTAssertEqual($0 as? ChatError, .response(.empty)) }
        for data in [Data("broken".utf8), Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8),
                     deepSeekEnvelope(valid, tools: [["id": "unexpected"]])] {
            XCTAssertThrowsError(try DeepSeekAPI.text(from: data)) { XCTAssertEqual($0 as? ChatError, .response(.schema)) }
        }
    }

    func testEscapedSecretIsRemovedAfterJSONDecodingAndAdviceStaysText() throws {
        var call = deepSeekCall(1, key: "fixture-secret")
        let json = #"{"move":"e2e4","taunt":"\u0066ixture-secret","self_notes":"\u0066ixture-secret","analysis":"PRIVATE_EXTRA_FIELD"}"#
        let result = try DeepSeekAPI.reply(from: deepSeekEnvelope(json), for: call)
        XCTAssertEqual(ChatParser.moveIntent(from: result)?.taunt, "[REDACTED]")
        XCTAssertEqual(ChatParser.moveIntent(from: result)?.selfNotes, "[REDACTED]")
        XCTAssertFalse(result.contains("PRIVATE_EXTRA_FIELD"))
        XCTAssertThrowsError(try DeepSeekAPI.reply(from: deepSeekEnvelope("e2e4"), for: call))
        call.responseFormat = .text
        XCTAssertEqual(try DeepSeekAPI.reply(from: deepSeekEnvelope("Remember fixture-secret"), for: call), "Remember [REDACTED]")
    }

    func testHTTPFailuresDoNotRetryOrExposeBody() async throws {
        let fixtures: [(Int, APIErrorReason)] = [(400, .request), (401, .authentication), (402, .balance), (403, .permission),
                                                (404, .modelAccess), (422, .request), (429, .rateLimit), (500, .server), (503, .server)]
        for (status, reason) in fixtures {
            let server = MiniHTTPServer(), seen = DeepSeekRequests()
            server.handler = { request in
                seen.append(request)
                return .init(status: status, body: Data(#"{"error":{"message":"deepseek-secret-key-do-not-show"}}"#.utf8))
            }
            try server.start(); defer { server.stop() }
            do {
                _ = try await DeepSeekTransport(timeout: 3).complete(deepSeekCall(server.port))
                XCTFail("Expected HTTP error")
            } catch let error as ChatError {
                XCTAssertEqual(error, .http(status: status, reason: reason))
                XCTAssertFalse(error.userMessage.contains("deepseek-secret-key-do-not-show"))
            }
            XCTAssertEqual(seen.values.count, 1)
        }
        XCTAssertTrue(APIErrorReason.balance.userMessage.contains("балансе DeepSeek"))
    }

    func testRedirectNeverReachesOtherOriginForChatOrCatalog() async throws {
        let first = MiniHTTPServer(), other = MiniHTTPServer(), received = DeepSeekRequests()
        other.handler = { request in received.append(request); return .init(status: 200, body: deepSeekEnvelope("unexpected")) }
        try other.start(); defer { other.stop() }
        first.handler = { _ in .init(status: 307, body: Data(), headers: ["Location": "http://127.0.0.1:\(other.port)/stolen"]) }
        try first.start(); defer { first.stop() }
        do { _ = try await DeepSeekTransport(timeout: 3).complete(deepSeekCall(first.port)); XCTFail("Redirect accepted") }
        catch let error as ChatError { XCTAssertEqual(error, .http(status: 307, reason: .request)) }
        do { _ = try await DeepSeekAPI.catalog(baseURL: localURL(first.port), apiKey: "fixture", timeout: 3); XCTFail("Redirect accepted") }
        catch let error as ChatError { XCTAssertEqual(error, .http(status: 307, reason: .request)) }
        XCTAssertTrue(received.values.isEmpty)
    }

    func testCatalogRetainsIDsNamesAndIgnoresAdditionalMetadata() async throws {
        let server = MiniHTTPServer(), seen = DeepSeekRequests()
        server.handler = { request in
            seen.append(request)
            return .init(status: 200, body: Data(#"{"data":[{"id":"deepseek-v4-pro","name":"Pro","effort":{"supported_levels":["high"]}},{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}"#.utf8))
        }
        try server.start(); defer { server.stop() }
        let models = try await DeepSeekAPI.catalog(baseURL: localURL(server.port), apiKey: " fixture-key\n", timeout: 3)
        XCTAssertEqual(models.map(\.id), ["deepseek-v4-pro", "deepseek-flash"])
        XCTAssertEqual(models.map(\.name), ["Pro", "deepseek-flash"])
        XCTAssertEqual(seen.values[0].path, "/models")
        XCTAssertEqual(seen.values[0].headers["authorization"], "Bearer fixture-key")
        XCTAssertTrue(seen.values[0].bodyText.isEmpty)
        XCTAssertEqual(try DeepSeekAPI.parseModels(Data(#"{"data":[]}"#.utf8), key: "k"), [])
        XCTAssertThrowsError(try DeepSeekAPI.parseModels(Data(#"{"data":[{}]}"#.utf8), key: "k"))
        XCTAssertThrowsError(try DeepSeekAPI.parseModels(Data(#"{"data":[{"id":"fixture-secret"}]}"#.utf8), key: "fixture-secret"))
    }

    @MainActor
    func testCatalogIgnoresOldKeyAndKeepsPreviousModelsOnFailure() async throws {
        let gate = DeepSeekCatalogGate()
        let connection = DeepSeekConnection(load: { try await gate.load($0) })
        connection.refresh(key: "old")
        try await waitFor { gate.pending["old"] != nil }
        connection.keyChanged()
        connection.refresh(key: "new")
        try await waitFor { gate.pending["new"] != nil }
        gate.resolve("new", .success([.init(id: "new-model", name: "New")]))
        try await waitFor { !connection.busy }
        gate.resolve("old", .success([.init(id: "old-model", name: "Old")]))
        await Task.yield()
        XCTAssertEqual(connection.models.map(\.id), ["new-model"])
        connection.refresh(key: "new")
        try await waitFor { gate.pending["new"] != nil }
        gate.resolve("new", .failure(ChatError.http(status: 402, reason: .balance)))
        try await waitFor { !connection.busy }
        XCTAssertEqual(connection.models.map(\.id), ["new-model"])
        XCTAssertTrue(connection.status.contains("балансе DeepSeek"))
        connection.keyChanged()
        XCTAssertTrue(connection.models.isEmpty)
        connection.refresh(key: " ")
        XCTAssertFalse(connection.busy)
        XCTAssertTrue(connection.status.contains("Введите"))
    }

    func testTimeoutAndCancellationRemainDistinct() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeepSeekFailureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = DeepSeekTransport(session: session)
        var call = deepSeekCall(1)
        call.url = URL(string: "https://deepseek-fixture.invalid/timeout")!
        do { _ = try await transport.complete(call); XCTFail("Expected timeout") }
        catch let error as ChatError { XCTAssertEqual(error, .timeout) }
        call.url = URL(string: "https://deepseek-fixture.invalid/pending")!
        let pending = Task { try await transport.complete(call) }
        try await Task.sleep(nanoseconds: 30_000_000)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testDeepSeekKeychainAndSessionRoundTrip() throws {
        let store = KeychainSecretStore(service: "com.chessarena.tests.deepseek.\(UUID().uuidString)")
        defer { try? store.delete(account: "deepseek") }
        try store.save(account: "deepseek", secret: "fixture-deepseek-secret")
        XCTAssertEqual(try store.load(account: "deepseek"), "fixture-deepseek-secret")
        XCTAssertNil(try store.load(account: "grok"))
        var black = PlayerConfiguration(provider: .deepseek); black.model = "deepseek-flash"
        let state = SavedSession(game: nil, series: MatchSeries(), white: .init(provider: .deepseek), black: black,
                                 hostModel: "host-model", language: .russian, useChatGPTLogin: false,
                                 camera: .init(manual: false, yaw: 0, pitch: 0, distance: 12), hostProvider: .claude)
        let data = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-deepseek-secret"))
        let saved = try JSONDecoder().decode(SavedSession.self, from: data)
        XCTAssertEqual(saved.white.model, ModelCatalog.deepSeekModel)
        XCTAssertEqual(saved.black.model, "deepseek-flash")
        XCTAssertEqual(saved.hostProvider, .claude)
        XCTAssertEqual(saved.hostModel, "host-model")
    }

    private func payload(_ request: MiniHTTPServer.Incoming) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.bodyText.utf8)) as? [String: Any])
    }
}

private func localURL(_ port: UInt16) -> URL { URL(string: "http://127.0.0.1:\(port)")! }
private func deepSeekCall(_ port: UInt16, key: String = "fixture-key") -> ChatCall {
    ChatCall(url: localURL(port).appendingPathComponent("chat/completions"), apiKey: key,
             model: ModelCatalog.deepSeekModel, system: "Reply with JSON", user: "FEN: current",
             route: .deepseek, effort: "high", responseFormat: .jsonObject)
}
private func deepSeekEnvelope(_ content: String, finish: String = "stop", reasoning: String = "private", tools: [[String: String]] = []) -> Data {
    try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finish,
        "message": ["content": content, "reasoning_content": reasoning, "tool_calls": tools]]]])
}
private final class DeepSeekRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MiniHTTPServer.Incoming] = []
    var values: [MiniHTTPServer.Incoming] { lock.lock(); defer { lock.unlock() }; return items }
    func append(_ item: MiniHTTPServer.Incoming) { lock.lock(); defer { lock.unlock() }; items.append(item) }
}
private final class RejectDeepSeekFallback: ChatTransport {
    func complete(_ call: ChatCall) async throws -> String { XCTFail("Wrong route"); throw ChatError.transport }
}
@MainActor private final class DeepSeekCatalogGate {
    var pending: [String: CheckedContinuation<[DeepSeekModel], Error>] = [:]
    func load(_ key: String) async throws -> [DeepSeekModel] { try await withCheckedThrowingContinuation { pending[key] = $0 } }
    func resolve(_ key: String, _ result: Result<[DeepSeekModel], Error>) { pending.removeValue(forKey: key)?.resume(with: result) }
}
@MainActor private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for fixture")
}
private final class DeepSeekFailureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/timeout" { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
    }
    override func stopLoading() { }
}
