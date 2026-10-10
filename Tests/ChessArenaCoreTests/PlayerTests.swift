import Darwin
import Foundation
import XCTest
@testable import ChessArenaCore

final class PlayerTests: XCTestCase {
    func testHTTPFailuresKeepSafeActionableReasons() async throws {
        let fixtures: [(Int, String, APIErrorReason)] = [
            (401, "invalid_api_key", .authentication),
            (404, "model_not_found", .modelAccess),
            (429, "insufficient_quota", .quota),
            (429, "rate_limit_exceeded", .rateLimit),
            (403, "unsupported_country_region_territory", .region),
            (403, "unknown", .permission),
            (503, "unknown", .server),
            (400, "unknown", .request),
        ]
        for (status, code, reason) in fixtures {
            let server = MiniHTTPServer()
            let seen = SeenRequest()
            let secret = "sk-test-do-not-display-this-key"
            server.handler = { incoming in
                seen.store(incoming)
                let body = try! JSONSerialization.data(withJSONObject: [
                    "error": ["code": code, "message": "Incorrect API key: \(secret)"]
                ])
                return MiniHTTPServer.Outgoing(status: status, body: body)
            }
            try server.start()
            defer { server.stop() }
            let call = ChatCall(url: URL(string: "http://127.0.0.1:\(server.port)/chat/completions")!, apiKey: "  \(secret)\n", model: " chat-latest\n", system: "test", user: "test")
            do {
                _ = try await URLSessionChatTransport(timeout: 3).complete(call)
                XCTFail("Expected HTTP \(status)")
            } catch let error as ChatError {
                XCTAssertEqual(error, .http(status: status, reason: reason))
                XCTAssertTrue(error.userMessage.contains("HTTP \(status)"))
                XCTAssertFalse(error.userMessage.contains(secret))
                XCTAssertFalse(String(describing: error).contains(secret))
            }
            let incoming = try XCTUnwrap(seen.value)
            XCTAssertEqual(incoming.headers["authorization"], "Bearer \(secret)")
            let payload = try JSONSerialization.jsonObject(with: Data(incoming.bodyText.utf8)) as? [String: Any]
            XCTAssertEqual(payload?["model"] as? String, "chat-latest")
        }
    }

    func testDefaultSeatsAndMoveParsing() async throws {
        let white = Seat.defaultWhite(apiKey: "white-key")
        let black = Seat.defaultBlack(apiKey: "black-key")
        XCTAssertEqual(white.completionsURL.absoluteString, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(white.model, "grok-4.7")
        XCTAssertEqual(black.completionsURL.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(black.model, "chat-latest")

        let server = MiniHTTPServer()
        let seen = SeenRequest()
        server.handler = { incoming in
            seen.store(incoming)
            let body = """
            {"choices":[{"message":{"content":"{\\"move\\":\\"e2e4\\",\\"taunt\\":\\"After you.\\"}"}}]}
            """.data(using: .utf8)!
            return MiniHTTPServer.Outgoing(status: 200, body: body)
        }
        try server.start()
        defer { server.stop() }

        let position = Position.standard()
        let prompt = Prompts.player(
            side: .white,
            fen: position.fen,
            legal: position.legalMoves().map(\.uci).sorted(),
            history: [],
            rejection: nil
        )
        XCTAssertTrue(prompt.user.contains(position.fen))
        XCTAssertTrue(prompt.user.contains("e2e4"))
        let call = ChatCall(
            url: URL(string: "http://127.0.0.1:\(server.port)/chat/completions")!,
            apiKey: white.apiKey,
            model: white.model,
            system: prompt.system,
            user: prompt.user
        )
        let transport = URLSessionChatTransport(timeout: 3)
        let content = try await transport.complete(call)
        let intent = try XCTUnwrap(ChatParser.moveIntent(from: content))
        XCTAssertEqual(intent.move, "e2e4")
        XCTAssertEqual(intent.taunt, "After you.")
        let incoming = try XCTUnwrap(seen.value)
        XCTAssertEqual(incoming.headers["authorization"], "Bearer white-key")
        let request = requestText(incoming.bodyText)
        XCTAssertTrue(request.contains("grok-4.7"), "headers=\(incoming.headers) body=\(incoming.bodyText.prefix(500))")
        XCTAssertTrue(request.contains(position.fen), "body=\(incoming.bodyText.prefix(500))")
        XCTAssertTrue(request.contains("e2e4"), "body=\(incoming.bodyText.prefix(500))")
        XCTAssertNil(ChatParser.moveIntent(from: "not a move"))
    }

    @MainActor
    func testUnreadableBodyCountsAsAnAttemptAndADropPausesTheSameSeat() async throws {
        let server = MiniHTTPServer()
        let seen = SeenList()
        let gate = AttemptGate()
        server.handler = { incoming in
            seen.add(incoming)
            let player = requestText(incoming.bodyText).contains("Reply with JSON")
            if player && gate.mode == .dropFirstPlayer {
                gate.mode = .answer
                return nil
            }
            if player && gate.mode == .unreadable {
                return MiniHTTPServer.Outgoing(status: 200, body: Data("nope".utf8))
            }
            let content = player ? "{\"move\":\"e2e4\",\"taunt\":\"Again.\"}" : "The seat is still White."
            return MiniHTTPServer.Outgoing(status: 200, body: chatEnvelope(content))
        }
        try server.start()
        defer { server.stop() }

        gate.mode = .unreadable
        let unreadable = try makeHTTPEngine(port: server.port)
        try await unreadable.start(at: 0)
        try await waitUntil { unreadable.moveRequestCount >= 2 }
        XCTAssertFalse(unreadable.paused)
        XCTAssertEqual(unreadable.referee.position.fen, Position.standard().fen)
        try await waitUntil(timeout: 6) { unreadable.speech.contains { $0.kind == .resignation } }

        gate.mode = .dropFirstPlayer
        seen.clear()
        let dropped = try makeHTTPEngine(port: server.port)
        try await dropped.start(at: 0)
        try await waitUntil { dropped.paused }
        XCTAssertEqual(dropped.referee.position.fen, Position.standard().fen)
        let requests = dropped.moveRequestCount
        dropped.resume()
        try await waitUntil {
            dropped.moveRequestCount > requests &&
                seen.values.map { requestText($0.bodyText) }.filter(isOpeningWhite).count >= 2
        }
        let white = seen.values.map { requestText($0.bodyText) }.filter(isOpeningWhite)
        XCTAssertGreaterThanOrEqual(white.count, 2)
        XCTAssertTrue(white.allSatisfy { $0.contains("grok-4.7") })
    }

    @MainActor
    private func makeHTTPEngine(port: UInt16) throws -> MatchEngine {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = MatchArchive(directory: directory, whiteName: "Grok", blackName: "ChatGPT")
        let base = URL(string: "http://127.0.0.1:\(port)/v1")!
        let white = Seat(name: "Grok", baseURL: base, model: ModelCatalog.grokModel, apiKey: "white-key", side: .white)
        let black = Seat(name: "ChatGPT", baseURL: base, model: ModelCatalog.chatGPTModel, apiKey: "black-key", side: .black)
        let host = Seat(name: "Host", baseURL: base, model: ModelCatalog.grokModel, apiKey: "white-key", side: .white)
        return MatchEngine(
            scene: BoardScene(),
            voice: ScriptedVoice(),
            transport: URLSessionChatTransport(timeout: 3),
            archive: archive,
            white: white,
            black: black,
            host: host
        )
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ predicate: @MainActor () -> Bool) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testKeychainRoundTripStaysOffThePicture() throws {
        let secret = "CHESSARENA-SECRET-KEY-9f3c2a7b"
        let store = KeychainSecretStore(service: "com.chessarena.tests.\(UUID().uuidString)")
        try store.save(account: "grok", secret: secret)
        XCTAssertEqual(try store.load(account: "grok"), secret)
        let picture = BroadcastPicture.empty
        XCTAssertFalse(picture.broadcastText.contains(secret))
        try store.delete(account: "grok")
        XCTAssertNil(try store.load(account: "grok"))
    }
}

private func isOpeningWhite(_ text: String) -> Bool {
    text.contains("You are White") && text.contains(Position.standard().fen)
}

private func requestText(_ body: String) -> String {
    let unescaped = body.replacingOccurrences(of: "\\/", with: "/")
    guard let data = unescaped.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return unescaped
    }
    let model = json["model"] as? String ?? ""
    let messages = (json["messages"] as? [[String: Any]])?.compactMap { $0["content"] as? String }.joined(separator: "\n") ?? ""
    return model + "\n" + messages
}

private func chatEnvelope(_ content: String) -> Data {
    let object: [String: Any] = ["choices": [["message": ["content": content]]]]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private final class AttemptGate: @unchecked Sendable {
    enum Mode { case unreadable, dropFirstPlayer, answer }
    private let lock = NSLock()
    private var stored: Mode = .answer
    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class SeenList: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MiniHTTPServer.Incoming] = []
    func add(_ incoming: MiniHTTPServer.Incoming) {
        lock.lock()
        stored.append(incoming)
        lock.unlock()
    }
    func clear() {
        lock.lock()
        stored.removeAll()
        lock.unlock()
    }
    var values: [MiniHTTPServer.Incoming] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class SeenRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MiniHTTPServer.Incoming?
    func store(_ incoming: MiniHTTPServer.Incoming) {
        lock.lock()
        stored = incoming
        lock.unlock()
    }
    var value: MiniHTTPServer.Incoming? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class MiniHTTPServer: @unchecked Sendable {
    struct Incoming {
        var path: String
        var headers: [String: String]
        var bodyText: String
    }
    struct Outgoing {
        var status: Int
        var body: Data
    }

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "chessarena.http.test")
    private(set) var port: UInt16 = 0
    var handler: ((Incoming) -> Outgoing?)?

    func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw URLError(.cannotConnectToHost) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listenFD, 8) == 0 else { throw URLError(.cannotConnectToHost) }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &length)
            }
        }
        guard named == 0 else { throw URLError(.cannotConnectToHost) }
        port = CFSwapInt16BigToHost(resolved.sin_port)
        source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source?.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source?.resume()
    }

    func stop() {
        source?.cancel()
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
    }

    private func acceptClient() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        queue.async {
            self.serve(client)
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let separator = Data("\r\n\r\n".utf8)
        while data.range(of: separator) == nil {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { return }
            data.append(buffer, count: count)
            if data.count > 2_000_000 { return }
        }
        guard let headerEnd = data.range(of: separator) else { return }
        let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        var body = Data(data[headerEnd.upperBound...])
        if header.lowercased().contains("expect: 100-continue") {
            let cont = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
            cont.withUnsafeBytes { raw in
                _ = write(client, raw.baseAddress, raw.count)
            }
        }
        if header.lowercased().contains("transfer-encoding: chunked") {
            body = decodeChunks(client, seeded: body, buffer: &buffer)
        } else {
            let length = contentLength(header)
            while body.count < length {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            if length > 0 {
                body = Data(body.prefix(length))
            }
        }
        let incoming = parse(header: header, body: body)
        guard let outgoing = handler?(incoming) else { return }
        let response = "HTTP/1.1 \(outgoing.status) OK\r\nContent-Length: \(outgoing.body.count)\r\nConnection: close\r\n\r\n"
        var bytes = Data(response.utf8)
        bytes.append(outgoing.body)
        bytes.withUnsafeBytes { raw in
            _ = write(client, raw.baseAddress, raw.count)
        }
    }

    private func decodeChunks(_ client: Int32, seeded: Data, buffer: inout [UInt8]) -> Data {
        var pending = seeded
        var decoded = Data()
        while true {
            guard let lineEnd = pending.range(of: Data("\r\n".utf8)) else {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { return decoded }
                pending.append(buffer, count: count)
                continue
            }
            let sizeText = String(data: pending[..<lineEnd.lowerBound], encoding: .utf8) ?? ""
            let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) ?? 0
            var rest = Data(pending[lineEnd.upperBound...])
            if size == 0 { return decoded }
            while rest.count < size + 2 {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { return decoded }
                rest.append(buffer, count: count)
            }
            decoded.append(rest.prefix(size))
            pending = Data(rest.dropFirst(size + 2))
        }
    }

    private func contentLength(_ header: String) -> Int {
        for line in header.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        }
        return 0
    }

    private func parse(header: String, body: Data) -> Incoming {
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return Incoming(path: path, headers: headers, bodyText: String(data: body, encoding: .utf8) ?? "")
    }
}
