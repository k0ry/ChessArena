import Foundation

/// Routes only the OpenAI seat through the app's authorized ChatGPT session.
public final class ArenaChatTransport: ChatTransport {
    private let api: ChatTransport
    private let connection: ChatGPTConnection?
    private let network: URLSession
    private let gemini: GeminiCLI?
    private let anthropic: ChatTransport
    private let claude: ClaudeCLI?
    private let lc0: ChatTransport
    private let deepseek: ChatTransport

    public init(connection: ChatGPTConnection?, api: ChatTransport = URLSessionChatTransport(), network: URLSession = .shared,
                gemini: GeminiCLI? = nil, anthropic: ChatTransport = AnthropicTransport(), claude: ClaudeCLI? = nil,
                deepseek: ChatTransport = DeepSeekTransport(), lc0: ChatTransport = LC0Transport()) {
        self.lc0 = lc0
        self.deepseek = deepseek
        self.gemini = gemini
        self.anthropic = anthropic
        self.claude = claude
        self.connection = connection; self.api = api; self.network = network
    }

    public func requestURL(for call: ChatCall) -> URL {
        if call.route == .lc0 { return LC0Transport.localURL }
        if call.route == .deepseek { return deepseek.requestURL(for: call) }
        if call.route == .geminiCLI { return URL(string: "local-cli://antigravity")! }
        if call.route == .anthropic { return call.url }
        if call.route == .claudeCLI { return ClaudeCLI.localURL }
        if call.url.host == "api.openai.com", connection != nil {
            return URL(string: "https://api.openai.com/v1/responses")!
        }
        return api.requestURL(for: call)
    }

    public func complete(_ call: ChatCall) async throws -> String {
        if call.route == .lc0 { return try await lc0.complete(call) }
        if call.route == .deepseek { return try await deepseek.complete(call) }
        if call.route == .geminiCLI {
            guard let gemini else { throw ChatError.cli(.missing) }
            return try await gemini.complete(call)
        }
        if call.route == .anthropic { return try await anthropic.complete(call) }
        if call.route == .claudeCLI {
            guard let claude else { throw ChatError.claudeCLI(.missing) }
            return try await claude.complete(call)
        }
        guard call.url.host == "api.openai.com", let connection else { return try await api.complete(call) }
        let token: String
        do { token = try await connection.accessToken() }
        catch { throw ChatError.http(status: 401, reason: .authentication) }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"; request.timeoutInterval = RequestTimeouts.player
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": call.model, "instructions": call.system,
            "input": call.inputMessages,
            "store": false, "stream": true
        ])
        do {
            return try await NetworkTrace.track(.responses, request: request) { trace in
                let (bytes, response) = try await network.bytes(for: request)
                await trace.response(response)
                guard let http = response as? HTTPURLResponse else { throw ChatError.transport }
                if !(200..<300).contains(http.statusCode) {
                    var errorData = Data()
                    for try await byte in bytes { errorData.append(byte); if errorData.count >= 16384 { break } }
                    await trace.payload(bytes: errorData.count)
                    throw ChatError.http(status: http.statusCode, reason: APIErrorReason.classify(status: http.statusCode, data: errorData))
                }
                var parser = ResponsesStream()
                var received = 0
                do {
                    for try await line in bytes.lines {
                        received += line.utf8.count
                        if let result = try parser.consume(line) {
                            await trace.payload(bytes: received)
                            return result
                        }
                    }
                    throw ChatError.unreadable
                } catch {
                    await trace.payload(bytes: received)
                    throw error
                }
            }
        } catch let error as URLError where error.code == .timedOut { throw ChatError.timeout }
    }
}

struct ResponsesStream {
    private var output = ""
    mutating func consume(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let content = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard content != "[DONE]", let data = content.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return nil }
        switch type {
        case "response.output_text.delta":
            output += event["delta"] as? String ?? ""
            guard output.utf8.count < 1_000_000 else { throw ChatError.unreadable }
        case "response.failed", "error":
            let response = event["response"] as? [String: Any]
            let error = response?["error"] ?? event["error"] ?? event
            let data = try JSONSerialization.data(withJSONObject: ["error": error])
            throw ChatError.http(status: 400, reason: APIErrorReason.classify(status: 400, data: data))
        case "response.incomplete": throw ChatError.unreadable
        case "response.completed":
            guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed" else { throw ChatError.unreadable }
            let items = response["output"] as? [[String: Any]] ?? []
            let finalText = items.filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
            let text = finalText.isEmpty ? output : finalText
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.unreadable }
            return text
        default: break
        }
        return nil
    }
}
