import Foundation

public enum NeuralProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case grok = "Grok"
    case chatGPT = "ChatGPT"
    case gemini = "Gemini"
    case claude = "Claude"
    case deepseek = "DeepSeek"
    case lc0 = "LC0"

    public var id: String { rawValue }
    public var supportsHost: Bool { self != .gemini && self != .deepseek && self != .lc0 }
    public var defaultModel: String {
        switch self {
        case .grok: return ModelCatalog.grokModel
        case .chatGPT: return ModelCatalog.chatGPTModel
        case .gemini: return GeminiCLI.defaultModel
        case .claude: return ModelCatalog.claudeModel
        case .deepseek: return ModelCatalog.deepSeekModel
        case .lc0: return "Leela Chess Zero"
        }
    }
    /// Default access point; Claude's actual route depends on the chosen access mode in `ProviderKeys`.
    public var baseURL: URL {
        switch self {
        case .grok: return ModelCatalog.grokAPI
        case .chatGPT: return ModelCatalog.openAIAPI
        case .gemini: return URL(string: "local-cli://antigravity")!
        case .claude: return ModelCatalog.anthropicAPI
        case .deepseek: return ModelCatalog.deepSeekAPI
        case .lc0: return LC0Transport.localURL
        }
    }
}

/// How Claude is reached: the subscription through the local Claude Code CLI, or an Anthropic API key.
public enum ClaudeAccess: String, CaseIterable, Sendable, Codable {
    case subscription, apiKey
}

/// One credential per provider plus the Claude access mode. A seat receives only the key of its own provider.
public struct ProviderKeys: Equatable, Sendable {
    public var grok: String
    public var chatGPT: String
    public var anthropic: String
    public var deepseek: String
    public var claudeAccess: ClaudeAccess

    public init(grok: String = "", chatGPT: String = "", anthropic: String = "", claudeAccess: ClaudeAccess = .subscription, deepseek: String = "") {
        self.grok = grok; self.chatGPT = chatGPT; self.anthropic = anthropic; self.claudeAccess = claudeAccess
        self.deepseek = deepseek
    }

    public func key(for provider: NeuralProvider) -> String {
        let value: String
        switch provider {
        case .grok: value = grok
        case .chatGPT: value = chatGPT
        case .claude: value = claudeAccess == .apiKey ? anthropic : ""
        case .gemini, .lc0: value = ""
        case .deepseek: value = deepseek
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func route(for provider: NeuralProvider) -> ChatRoute {
        switch provider {
        case .gemini: return .geminiCLI
        case .claude: return claudeAccess == .apiKey ? .anthropic : .claudeCLI
        case .grok, .chatGPT: return .http
        case .deepseek: return .deepseek
        case .lc0: return .lc0
        }
    }

    public func baseURL(for provider: NeuralProvider) -> URL {
        if provider == .claude, claudeAccess == .subscription { return ClaudeCLI.localURL }
        return provider.baseURL
    }
}

public struct PlayerConfiguration: Equatable, Sendable, Codable {
    public var provider: NeuralProvider {
        didSet {
            if provider != oldValue { model = provider.defaultModel }
        }
    }
    public var model: String
    /// Optional so older sessions keep the original 16,384-token budget.
    public var maxOutputTokens: Int? = nil

    public init(provider: NeuralProvider) {
        self.provider = provider
        self.model = provider.defaultModel
    }

    public func seat(side: Side, keys: ProviderKeys) -> Seat {
        var seat = Seat(name: provider.rawValue, baseURL: keys.baseURL(for: provider),
             model: model.trimmingCharacters(in: .whitespacesAndNewlines),
             apiKey: keys.key(for: provider), side: side, route: keys.route(for: provider))
        seat.maxOutputTokens = maxOutputTokens
        return seat
    }

    public func seat(side: Side, grokKey: String, chatKey: String) -> Seat {
        seat(side: side, keys: ProviderKeys(grok: grokKey, chatGPT: chatKey))
    }
}
