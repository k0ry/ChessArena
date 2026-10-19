import Foundation

/// Whitelisted response metadata only. No content, reasoning, headers or credentials.
public struct ResponseMetadata: Codable, Equatable, Sendable {
    public var finishReason: String
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?

    static func chatCompletion(_ data: Data) -> ResponseMetadata {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let choices = body?["choices"] as? [[String: Any]]
        let raw = choices?.first?["finish_reason"] as? String ?? "missing"
        let known = ["stop", "length", "content_filter", "tool_calls", "insufficient_system_resource", "aborted", "missing"]
        let usage = body?["usage"] as? [String: Any]
        func tokens(_ key: String) -> Int? { guard let value = usage?[key] as? Int, value >= 0 else { return nil }; return value }
        return ResponseMetadata(finishReason: known.contains(raw) ? raw : "unknown", promptTokens: tokens("prompt_tokens"),
                                completionTokens: tokens("completion_tokens"), totalTokens: tokens("total_tokens"))
    }
}

public enum ResponseTrace {
    @TaskLocal public static var receive: (@Sendable (ResponseMetadata) async -> Void)?
}

public struct MatchDiagnostic: Codable, Sendable {
    public var roundID: UUID
    public var requestID: UUID?
    public var event: String
    public var timestamp = Date()
    public var provider: String?
    public var model: String?
    public var side: Side?
    public var ply: Int
    public var fen: String
    public var attempt: Int?
    public var budget: Int?
    public var response: ResponseMetadata?
    public var reason: String?
    public var duration: TimeInterval?
    public var retryAt: TimeInterval?
    public var logicalTurnID: String?
    public var timeoutSeconds: TimeInterval?
    public var timeoutSource: String?
    public var retryDecision: String?
}

extension ChatError {
    func timeoutSource(deadlineExpired: Bool) -> String? {
        switch self {
        case .timeout: return deadlineExpired ? "request_deadline" : "transport"
        case .cli(.timeout): return "gemini_cli"
        case .claudeCLI(.timeout): return "claude_cli"
        case .lc0(.timeout): return "lc0"
        default: return nil
        }
    }

    var diagnosticCode: String {
        switch self {
        case .response(let reason): return reason.rawValue
        case .unreadable: return "unreadable"
        case .transport: return "network"
        case .timeout: return "timeout"
        case .refused: return "refused"
        case .http(let status, let reason): return "http_\(status)_\(reason.rawValue)"
        case .cli(let reason): return "gemini_cli_" + reason.rawValue
        case .claudeCLI(let reason): return "claude_cli_" + reason.rawValue
        case .lc0(let reason): return "lc0_" + reason.rawValue
        }
    }
}
