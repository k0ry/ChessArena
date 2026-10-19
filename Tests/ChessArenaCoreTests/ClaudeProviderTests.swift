import Foundation
import XCTest
@testable import ChessArenaCore

final class ClaudeProviderTests: XCTestCase {
    private let keys = ProviderKeys(grok: "grok-key", chatGPT: "openai-key", anthropic: "claude-key", claudeAccess: .apiKey)

    func testClaudeSeatRoutesToMessagesWithOnlyItsOwnKey() {
        var claude = PlayerConfiguration(provider: .claude)
        XCTAssertEqual(claude.model, "claude-opus-5-5")
        claude.model = " claude-sonnet-5-5 "
        let seat = claude.seat(side: .black, keys: keys)
        XCTAssertEqual(seat.route, .anthropic)
        XCTAssertEqual(seat.name, "Claude")
        XCTAssertEqual(seat.model, "claude-sonnet-5-5")
        XCTAssertEqual(seat.apiKey, "claude-key")
        XCTAssertEqual(seat.completionsURL.absoluteString, "https://api.anthropic.com/v1/messages")

        XCTAssertEqual(PlayerConfiguration(provider: .grok).seat(side: .white, keys: keys).apiKey, "grok-key")
        XCTAssertEqual(PlayerConfiguration(provider: .chatGPT).seat(side: .white, keys: keys).apiKey, "openai-key")
        XCTAssertEqual(PlayerConfiguration(provider: .gemini).seat(side: .white, keys: keys).apiKey, "")
        XCTAssertEqual(PlayerConfiguration(provider: .grok).seat(side: .white, keys: keys).route, .http)
        var subscription = keys; subscription.claudeAccess = .subscription
        XCTAssertEqual(PlayerConfiguration(provider: .claude).seat(side: .white, keys: subscription).route, .claudeCLI)
        XCTAssertEqual(PlayerConfiguration(provider: .claude).seat(side: .white, keys: subscription).apiKey, "")
        // The legacy two-key signature keeps its behavior and never invents an Anthropic key.
        XCTAssertEqual(PlayerConfiguration(provider: .claude).seat(side: .white, grokKey: "g", chatKey: "c").apiKey, "")
        XCTAssertEqual(PlayerConfiguration(provider: .chatGPT).seat(side: .white, grokKey: "g", chatKey: "c").apiKey, "c")
    }

    func testRequestShapeAndTextBlocksSkipThinking() async throws {
        let server = MiniHTTPServer()
        let seen = SeenIncoming()
        server.handler = { incoming in
            seen.store(incoming)
            let body: [String: Any] = [
                "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
                "stop_reason": "end_turn",
                "content": [
                    ["type": "thinking", "thinking": "SECRET REASONING e7e5", "signature": "sig"],
                    ["type": "text", "text": #"{"move":"e2e4","#],
                    ["type": "text", "text": #""taunt":"After you."}"#],
                ],
            ]
            return MiniHTTPServer.Outgoing(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
        }
        try server.start()
        defer { server.stop() }
        let call = ChatCall(url: URL(string: "http://127.0.0.1:\(server.port)/v1/messages")!, apiKey: " claude-key\n",
                            model: " claude-opus-5-5 ", system: "system text", user: "FEN: current",
                            selfNotes: "Castle soon.", route: .anthropic, gameAdvice: "Mind the king.", effort: "high")
        let text = try await AnthropicTransport(timeout: 3).complete(call)
        XCTAssertFalse(text.contains("SECRET REASONING"))
        let intent = try XCTUnwrap(ChatParser.moveIntent(from: text))
        XCTAssertEqual(intent.move, "e2e4")
        XCTAssertEqual(intent.taunt, "After you.")

        let incoming = try XCTUnwrap(seen.value)
        XCTAssertEqual(incoming.path, "/v1/messages")
        XCTAssertEqual(incoming.headers["x-api-key"], "claude-key")
        XCTAssertEqual(incoming.headers["anthropic-version"], "2023-06-01")
        XCTAssertNil(incoming.headers["authorization"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(incoming.bodyText.utf8)) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(payload["system"] as? String, "system text")
        XCTAssertEqual(payload["max_tokens"] as? Int, 16000)
        XCTAssertEqual((payload["output_config"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertNil(payload["thinking"])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertEqual(messages, call.inputMessages)
        XCTAssertEqual(messages.first, ["role": "user", "content": "FEN: current"])
        XCTAssertTrue(messages.allSatisfy { $0["role"] == "user" })
    }

    func testCommentatorEffortUsesShortBudgetAndNoEffortOmitsOutputConfig() {
        var call = ChatCall(url: ModelCatalog.anthropicAPI, apiKey: "k", model: "claude-opus-5-5", system: "s", user: "u", route: .anthropic, effort: "low")
        XCTAssertEqual(AnthropicAPI.body(for: call)["max_tokens"] as? Int, 2048)
        call.effort = nil
        let body = AnthropicAPI.body(for: call)
        XCTAssertEqual(body["max_tokens"] as? Int, 16000)
        XCTAssertNil(body["output_config"])
    }

    func testStopReasonsRefusalAndTruncation() throws {
        func envelope(_ stop: String, text: String?) -> Data {
            var content: [[String: Any]] = []
            if let text { content.append(["type": "text", "text": text]) }
            return try! JSONSerialization.data(withJSONObject: ["type": "message", "stop_reason": stop, "content": content])
        }
        XCTAssertEqual(try AnthropicAPI.text(from: envelope("end_turn", text: "fine")), "fine")
        XCTAssertThrowsError(try AnthropicAPI.text(from: envelope("refusal", text: nil))) { XCTAssertEqual($0 as? ChatError, .refused) }
        XCTAssertThrowsError(try AnthropicAPI.text(from: envelope("refusal", text: "partial"))) { XCTAssertEqual($0 as? ChatError, .refused) }
        XCTAssertThrowsError(try AnthropicAPI.text(from: envelope("max_tokens", text: #"{"move":"e2"#))) { XCTAssertEqual($0 as? ChatError, .response(.truncated)) }
        XCTAssertThrowsError(try AnthropicAPI.text(from: envelope("tool_use", text: "x"))) { XCTAssertEqual($0 as? ChatError, .unreadable) }
        XCTAssertThrowsError(try AnthropicAPI.text(from: envelope("end_turn", text: "  "))) { XCTAssertEqual($0 as? ChatError, .unreadable) }
        XCTAssertThrowsError(try AnthropicAPI.text(from: Data("nope".utf8))) { XCTAssertEqual($0 as? ChatError, .unreadable) }
        XCTAssertFalse(ChatError.refused.userMessage.isEmpty)
    }

    func testAnthropicErrorsMapToSafeReasons() async throws {
        let secret = "sk-ant-do-not-display-this-key"
        let fixtures: [(Int, String, String, APIErrorReason)] = [
            (401, "authentication_error", "invalid x-api-key \(secret)", .authentication),
            (403, "permission_error", "forbidden", .permission),
            (404, "not_found_error", "model: claude-nope", .modelAccess),
            (400, "invalid_request_error", "Your credit balance is too low to access the Anthropic API.", .quota),
            (402, "billing_error", "billing", .quota),
            (400, "invalid_request_error", "max_tokens: must be positive", .request),
            (413, "request_too_large", "too large", .request),
            (429, "rate_limit_error", "slow down", .rateLimit),
            (500, "api_error", "boom", .server),
            (529, "overloaded_error", "overloaded", .server),
        ]
        for (status, type, message, reason) in fixtures {
            let server = MiniHTTPServer()
            server.handler = { _ in
                let body = try! JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": type, "message": message]])
                return MiniHTTPServer.Outgoing(status: status, body: body)
            }
            try server.start()
            defer { server.stop() }
            let call = ChatCall(url: URL(string: "http://127.0.0.1:\(server.port)/v1/messages")!, apiKey: secret,
                                model: "claude-opus-5-5", system: "s", user: "u", route: .anthropic)
            do {
                _ = try await AnthropicTransport(timeout: 3).complete(call)
                XCTFail("Expected HTTP \(status)")
            } catch let error as ChatError {
                XCTAssertEqual(error, .http(status: status, reason: reason), "status \(status) \(type)")
                XCTAssertFalse(error.userMessage.contains(secret))
                XCTAssertFalse(String(describing: error).contains(secret))
            }
        }
        let wrongRoute = ChatCall(url: ModelCatalog.anthropicAPI, apiKey: "k", model: "m", system: "s", user: "u", route: .http)
        do { _ = try await AnthropicTransport(timeout: 3).complete(wrongRoute); XCTFail("route guard") }
        catch let error as ChatError { XCTAssertEqual(error, .transport) }
    }

    func testCatalogPaginatesFiltersAndSortsNewestFirst() async throws {
        let server = MiniHTTPServer()
        let seen = SeenIncomingList()
        server.handler = { incoming in
            seen.add(incoming)
            guard incoming.headers["x-api-key"] == "claude-key" else {
                let body = try! JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": "authentication_error", "message": "bad key"]])
                return MiniHTTPServer.Outgoing(status: 401, body: body)
            }
            let second = incoming.path.contains("after_id=claude-haiku-5-5")
            let page: [String: Any] = second ? [
                "data": [
                    ["type": "model", "id": "claude-opus-5-5", "display_name": "Claude Opus 5.5", "created_at": "2026-09-01T00:00:00Z"],
                    ["type": "model", "id": "claude-haiku-5-5", "display_name": "dup", "created_at": "2026-05-01T00:00:00Z"],
                ],
                "has_more": false, "first_id": "claude-opus-5-5", "last_id": "claude-haiku-5-5",
            ] : [
                "data": [
                    ["type": "model", "id": "claude-sonnet-5-5", "display_name": "Claude Sonnet 5.5", "created_at": "2026-07-01T00:00:00Z"],
                    ["type": "model", "id": "not-claude", "display_name": "Other", "created_at": "2027-01-01T00:00:00Z"],
                    ["type": "model", "id": "claude-haiku-5-5", "display_name": "Claude Haiku 5.5", "created_at": "2026-05-01T00:00:00Z"],
                ],
                "has_more": true, "first_id": "claude-sonnet-5-5", "last_id": "claude-haiku-5-5",
            ]
            return MiniHTTPServer.Outgoing(status: 200, body: try! JSONSerialization.data(withJSONObject: page))
        }
        try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(server.port)/v1")!
        let models = try await AnthropicAPI.catalog(baseURL: base, apiKey: "claude-key", timeout: 3)
        XCTAssertEqual(models.map(\.id), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(models.first?.name, "Claude Opus 5.5")
        let paths = seen.values.map(\.path)
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths[0].hasPrefix("/v1/models?"), paths[0])
        XCTAssertTrue(paths[0].contains("limit=100"))
        XCTAssertFalse(paths[0].contains("after_id"))
        XCTAssertTrue(paths[1].contains("after_id=claude-haiku-5-5"))
        XCTAssertTrue(seen.values.allSatisfy { $0.headers["anthropic-version"] == "2023-06-01" })

        do {
            _ = try await AnthropicAPI.catalog(baseURL: base, apiKey: "wrong", timeout: 3)
            XCTFail("expected 401")
        } catch let error as ChatError {
            XCTAssertEqual(error, .http(status: 401, reason: .authentication))
        }
    }

    @MainActor
    func testConnectionLoadsCatalogAndKeyChangeClearsIt() async throws {
        let server = MiniHTTPServer()
        server.handler = { _ in
            let page: [String: Any] = ["data": [["type": "model", "id": "claude-opus-5-5", "display_name": "Claude Opus 5.5", "created_at": "2026-09-01T00:00:00Z"]], "has_more": false]
            return MiniHTTPServer.Outgoing(status: 200, body: try! JSONSerialization.data(withJSONObject: page))
        }
        try server.start()
        defer { server.stop() }
        let connection = ClaudeConnection(baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!)
        XCTAssertFalse(connection.cliVerified)
        connection.refresh(key: "   ")
        XCTAssertFalse(connection.busy)
        XCTAssertTrue(connection.models.isEmpty)
        connection.refresh(key: "claude-key")
        let start = Date()
        while connection.busy, Date().timeIntervalSince(start) < 3 { try await Task.sleep(nanoseconds: 15_000_000) }
        XCTAssertEqual(connection.models.map(\.id), ["claude-opus-5-5"])
        XCTAssertTrue(connection.status.contains("1 "), connection.status)
        connection.keyChanged()
        XCTAssertTrue(connection.models.isEmpty)
    }

    func testSessionPersistsClaudeForSeatsAndHost() throws {
        var white = PlayerConfiguration(provider: .claude)
        white.model = "claude-sonnet-5-5"
        let state = SavedSession(game: nil, series: MatchSeries(), white: white, black: .init(provider: .gemini),
                                 hostModel: "claude-opus-5-5", language: .english, useChatGPTLogin: false,
                                 camera: .init(manual: false, yaw: 0, pitch: 0, distance: 12), hostProvider: .claude)
        let data = try JSONEncoder().encode(state)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"Claude\""))
        let restored = try JSONDecoder().decode(SavedSession.self, from: data)
        XCTAssertEqual(restored.white.provider, .claude)
        XCTAssertEqual(restored.white.model, "claude-sonnet-5-5")
        XCTAssertEqual(restored.hostConfiguration.provider, .claude)
        XCTAssertEqual(restored.hostConfiguration.model, "claude-opus-5-5")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("claude-key"))
    }
}

private final class SeenIncoming: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MiniHTTPServer.Incoming?
    func store(_ incoming: MiniHTTPServer.Incoming) { lock.lock(); stored = incoming; lock.unlock() }
    var value: MiniHTTPServer.Incoming? { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class SeenIncomingList: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MiniHTTPServer.Incoming] = []
    func add(_ incoming: MiniHTTPServer.Incoming) { lock.lock(); stored.append(incoming); lock.unlock() }
    var values: [MiniHTTPServer.Incoming] { lock.lock(); defer { lock.unlock() }; return stored }
}
