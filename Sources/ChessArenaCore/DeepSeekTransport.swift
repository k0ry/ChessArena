import Foundation

public struct DeepSeekModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
}

/// Reject redirects rather than forwarding a credential or replaying a paid request elsewhere.
final class DeepSeekRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum DeepSeekAPI {
    public static let maxTokens = 16_384
    public static let tokenBudgets = [8_192, 16_384, 32_768, 65_536, 131_072, 262_144, 393_216]

    static func request(url: URL, key: String, method: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func body(for call: ChatCall) -> [String: Any] {
        var body: [String: Any] = [
            "model": call.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [["role": "system", "content": call.system]] + call.inputMessages,
            "stream": false, "thinking": ["type": "enabled"], "reasoning_effort": "high",
            "max_tokens": call.maxOutputTokens ?? maxTokens,
        ]
        if call.responseFormat == .jsonObject { body["response_format"] = ["type": "json_object"] }
        return body
    }

    static func text(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], let choice = choices.first,
              let finish = choice["finish_reason"] as? String else { throw ChatError.response(.schema) }
        if finish == "length" { throw ChatError.response(.truncated) }
        if finish == "content_filter" { throw ChatError.refused }
        if finish == "insufficient_system_resource" || finish == "aborted" { throw ChatError.transport }
        guard finish == "stop", let message = choice["message"] as? [String: Any] else { throw ChatError.response(.schema) }
        guard let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.response(.empty) }
        if let calls = message["tool_calls"], !(calls is NSNull) {
            guard let array = calls as? [Any], array.isEmpty else { throw ChatError.response(.schema) }
        }
        // reasoning_content is deliberately never returned or retained by application state.
        return content
    }

    static func reason(status: Int) -> APIErrorReason {
        switch status {
        case 401: return .authentication
        case 402: return .balance
        case 403: return .permission
        case 404: return .modelAccess
        case 429: return .rateLimit
        case 500...599: return .server
        default: return .request
        }
    }

    static func parseModels(_ data: Data, key: String) throws -> [DeepSeekModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { throw ChatError.unreadable }
        var seen = Set<String>()
        return try items.compactMap { item in
            guard let id = item["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChatError.unreadable
            }
            // A malicious/error catalog must not publish the supplied credential in its IDs.
            guard key.isEmpty || !id.contains(key) else { throw ChatError.unreadable }
            guard seen.insert(id).inserted else { return nil }
            let name = item["name"] as? String ?? id
            return DeepSeekModel(id: id, name: redact(name, key: key))
        }
    }

    static func redact(_ text: String, key: String) -> String {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? text : text.replacingOccurrences(of: key, with: "[REDACTED]")
    }

    static func reply(from data: Data, for call: ChatCall) throws -> String {
        let content = try text(from: data)
        guard call.responseFormat == .jsonObject else { return redact(content, key: call.apiKey) }
        guard let intent = ChatParser.moveIntent(from: content) else { throw ChatError.response(.schema) }
        // Redact decoded fields, including keys echoed using JSON unicode escapes.
        // Only game fields survive; unexpected analysis fields never enter the log or archive.
        var result = ["move": redact(intent.move, key: call.apiKey), "taunt": redact(intent.taunt, key: call.apiKey)]
        if let notes = intent.selfNotes { result["self_notes"] = redact(notes, key: call.apiKey) }
        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
    }

    public static func catalog(baseURL: URL = ModelCatalog.deepSeekAPI, apiKey: String,
                               session: URLSession = .shared, timeout: TimeInterval = RequestTimeouts.host) async throws -> [DeepSeekModel] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = request(url: baseURL.appendingPathComponent("models"), key: key, method: "GET", timeout: timeout)
        let data = try await perform(request, operation: .deepSeekModels, session: session)
        return try parseModels(data, key: key)
    }

    static func perform(_ request: URLRequest, operation: NetworkOperation, session: URLSession) async throws -> Data {
        do {
            return try await NetworkTrace.track(operation, request: request) { trace in
                try Task.checkCancellation()
                let (data, response) = try await session.data(for: request, delegate: DeepSeekRequestDelegate())
                try Task.checkCancellation()
                await trace.response(response, bytes: data.count)
                guard let http = response as? HTTPURLResponse else { throw ChatError.transport }
                guard (200..<300).contains(http.statusCode) else {
                    throw ChatError.http(status: http.statusCode, reason: reason(status: http.statusCode))
                }
                return data
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where error.code == .timedOut { throw ChatError.timeout }
        catch let error as ChatError { throw error }
        catch { throw ChatError.transport }
    }
}

public final class DeepSeekTransport: ChatTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = RequestTimeouts.player) {
        self.session = session; self.timeout = timeout
    }

    public func requestTimeout(for call: ChatCall) -> TimeInterval? { timeout }

    public func complete(_ call: ChatCall) async throws -> String {
        guard call.route == .deepseek else { throw ChatError.transport }
        guard (1...393_216).contains(call.maxOutputTokens ?? DeepSeekAPI.maxTokens) else {
            throw ChatError.http(status: 400, reason: .request)
        }
        var request = DeepSeekAPI.request(url: call.url, key: call.apiKey, method: "POST", timeout: try RequestTiming.timeout(fallback: timeout))
        request.httpBody = try JSONSerialization.data(withJSONObject: DeepSeekAPI.body(for: call))
        let data = try await DeepSeekAPI.perform(request, operation: .deepSeekChat, session: session)
        await ResponseTrace.receive?(ResponseMetadata.chatCompletion(data))
        return try DeepSeekAPI.reply(from: data, for: call)
    }
}
