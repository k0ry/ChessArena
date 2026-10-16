import Foundation

public struct ClaudeModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// ISO 8601 creation date from the Models API; newest models are listed first.
    public let createdAt: String

    public init(id: String, name: String, createdAt: String = "") {
        self.id = id; self.name = name; self.createdAt = createdAt
    }
}

/// Anthropic Messages API and Models API over raw HTTP. The key travels only in the `x-api-key` header.
public enum AnthropicAPI {
    static let modelsPageLimit = 100
    static let modelsPageCap = 10

    static func request(url: URL, apiKey: String, method: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-api-key")
        request.setValue(ModelCatalog.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Reasoning tokens count against `max_tokens`; the commentator gets a short budget, players a generous one.
    static func maxTokens(effort: String?) -> Int { effort == "low" ? 2048 : 16000 }

    static func body(for call: ChatCall) -> [String: Any] {
        var payload: [String: Any] = [
            "model": call.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "max_tokens": maxTokens(effort: call.effort),
            "system": call.system,
            "messages": call.inputMessages,
        ]
        if let effort = call.effort, !effort.isEmpty {
            payload["output_config"] = ["effort": effort]
        }
        return payload
    }

    /// Only text blocks reach the game; thinking blocks and stop metadata never become a reply.
    static func text(from data: Data) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ChatError.unreadable }
        let stop = object["stop_reason"] as? String
        if stop == "refusal" { throw ChatError.refused }
        guard let content = object["content"] as? [[String: Any]] else { throw ChatError.unreadable }
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        if stop == "max_tokens" { throw ChatError.unreadable }
        if let stop, stop != "end_turn", stop != "stop_sequence" { throw ChatError.unreadable }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.unreadable }
        return text
    }

    static func parseModels(_ data: Data) throws -> (models: [ClaudeModel], hasMore: Bool, lastID: String?) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { throw ChatError.unreadable }
        let models = items.compactMap { item -> ClaudeModel? in
            guard let id = item["id"] as? String, validModel(id) else { return nil }
            return ClaudeModel(id: id, name: item["display_name"] as? String ?? id, createdAt: item["created_at"] as? String ?? "")
        }
        return (models, object["has_more"] as? Bool ?? false, object["last_id"] as? String)
    }

    static func validModel(_ model: String) -> Bool {
        model.range(of: #"^claude-[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// Full catalog for this key: newest first, without duplicates. Listing a model does not prove access to it.
    public static func catalog(baseURL: URL, apiKey: String, session: URLSession = .shared,
                               timeout: TimeInterval = RequestTimeouts.host) async throws -> [ClaudeModel] {
        var collected: [ClaudeModel] = []
        var seen = Set<String>()
        var after: String?
        for _ in 0..<modelsPageCap {
            var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
            var query = [URLQueryItem(name: "limit", value: String(modelsPageLimit))]
            if let after { query.append(URLQueryItem(name: "after_id", value: after)) }
            components.queryItems = query
            let request = Self.request(url: components.url!, apiKey: apiKey, method: "GET", timeout: timeout)
            let page = try await perform(request, operation: .anthropicModels, session: session) { data in
                try parseModels(data)
            }
            for model in page.models where seen.insert(model.id).inserted { collected.append(model) }
            guard page.hasMore, let last = page.lastID, last != after else { break }
            after = last
        }
        return collected.sorted { $0.createdAt > $1.createdAt }
    }

    static func perform<T>(_ request: URLRequest, operation: NetworkOperation, session: URLSession,
                           parse: (Data) throws -> T) async throws -> T {
        do {
            return try await NetworkTrace.track(operation, request: request) { trace in
                let (data, response) = try await session.data(for: request)
                await trace.response(response, bytes: data.count)
                guard let http = response as? HTTPURLResponse else { throw ChatError.transport }
                guard (200..<300).contains(http.statusCode) else {
                    throw ChatError.http(status: http.statusCode, reason: APIErrorReason.classifyAnthropic(status: http.statusCode, data: data))
                }
                return try parse(data)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where error.code == .timedOut { throw ChatError.timeout }
        catch let error as ChatError { throw error }
        catch { throw ChatError.transport }
    }
}

public final class AnthropicTransport: ChatTransport {
    public var session: URLSession
    public var timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = RequestTimeouts.player) {
        self.session = session
        self.timeout = timeout
    }

    public func complete(_ call: ChatCall) async throws -> String {
        guard call.route == .anthropic else { throw ChatError.transport }
        var request = AnthropicAPI.request(url: call.url, apiKey: call.apiKey, method: "POST", timeout: timeout)
        request.httpBody = try JSONSerialization.data(withJSONObject: AnthropicAPI.body(for: call))
        return try await AnthropicAPI.perform(request, operation: .anthropicMessages, session: session) { data in
            try AnthropicAPI.text(from: data)
        }
    }
}
