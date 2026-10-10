import Foundation

/// Routes only the OpenAI seat through the app's authorized ChatGPT session.
public final class ArenaChatTransport: ChatTransport {
    private let api: ChatTransport
    private let connection: ChatGPTConnection?
    private let network: URLSession

    public init(connection: ChatGPTConnection?, api: ChatTransport = URLSessionChatTransport(), network: URLSession = .shared) {
        self.connection = connection; self.api = api; self.network = network
    }

    public func requestURL(for call: ChatCall) -> URL {
        if call.url.host == "api.openai.com", connection != nil {
            return URL(string: "https://api.openai.com/v1/responses")!
        }
        return api.requestURL(for: call)
    }

    public func complete(_ call: ChatCall) async throws -> String {
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
            "input": [["role": "user", "content": call.user]],
            "store": false, "stream": true
        ])
        do {
            let (bytes, response) = try await network.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ChatError.transport }
            if !(200..<300).contains(http.statusCode) {
                var errorData = Data()
                for try await byte in bytes { errorData.append(byte); if errorData.count >= 16384 { break } }
                throw ChatError.http(status: http.statusCode, reason: APIErrorReason.classify(status: http.statusCode, data: errorData))
            }
            var parser = ResponsesStream()
            for try await line in bytes.lines {
                if let result = try parser.consume(line) { return result }
            }
            throw ChatError.unreadable
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
