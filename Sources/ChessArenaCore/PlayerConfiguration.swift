import Foundation

public enum NeuralProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case grok = "Grok"
    case chatGPT = "ChatGPT"
    case gemini = "Gemini"
    case claude = "Claude"

    public var id: String { rawValue }
    public var defaultModel: String {
        switch self {
        case .grok: return ModelCatalog.grokModel
        case .chatGPT: return ModelCatalog.chatGPTModel
        case .gemini: return GeminiCLI.defaultModel
        case .claude: return ModelCatalog.claudeModel
        }
    }
    /// Default access point; Claude's actual route depends on the chosen access mode in `ProviderKeys`.
    public var baseURL: URL {
        switch self {
        case .grok: return ModelCatalog.grokAPI
        case .chatGPT: return ModelCatalog.openAIAPI
        case .gemini: return URL(string: "local-cli://antigravity")!
        case .claude: return ModelCatalog.anthropicAPI
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
    public var claudeAccess: ClaudeAccess

    public init(grok: String = "", chatGPT: String = "", anthropic: String = "", claudeAccess: ClaudeAccess = .subscription) {
        self.grok = grok; self.chatGPT = chatGPT; self.anthropic = anthropic; self.claudeAccess = claudeAccess
    }

    public func key(for provider: NeuralProvider) -> String {
        let value: String
        switch provider {
        case .grok: value = grok
        case .chatGPT: value = chatGPT
        case .claude: value = claudeAccess == .apiKey ? anthropic : ""
        case .gemini: value = ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func route(for provider: NeuralProvider) -> ChatRoute {
        switch provider {
        case .gemini: return .geminiCLI
        case .claude: return claudeAccess == .apiKey ? .anthropic : .claudeCLI
        case .grok, .chatGPT: return .http
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

    public init(provider: NeuralProvider) {
        self.provider = provider
        self.model = provider.defaultModel
    }

    public func seat(side: Side, keys: ProviderKeys) -> Seat {
        Seat(name: provider.rawValue, baseURL: keys.baseURL(for: provider),
             model: model.trimmingCharacters(in: .whitespacesAndNewlines),
             apiKey: keys.key(for: provider), side: side, route: keys.route(for: provider))
    }

    public func seat(side: Side, grokKey: String, chatKey: String) -> Seat {
        seat(side: side, keys: ProviderKeys(grok: grokKey, chatGPT: chatKey))
    }
}
