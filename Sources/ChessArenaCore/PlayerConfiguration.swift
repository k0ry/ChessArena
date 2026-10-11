import Foundation

public enum NeuralProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case grok = "Grok"
    case chatGPT = "ChatGPT"
    case gemini = "Gemini"

    public var id: String { rawValue }
    public var defaultModel: String {
        switch self {
        case .grok: return ModelCatalog.grokModel
        case .chatGPT: return ModelCatalog.chatGPTModel
        case .gemini: return GeminiCLI.defaultModel
        }
    }
    public var baseURL: URL {
        switch self {
        case .grok: return ModelCatalog.grokAPI
        case .chatGPT: return ModelCatalog.openAIAPI
        case .gemini: return URL(string: "local-cli://antigravity")!
        }
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

    public func seat(side: Side, grokKey: String, chatKey: String) -> Seat {
        Seat(name: provider.rawValue, baseURL: provider.baseURL,
             model: model.trimmingCharacters(in: .whitespacesAndNewlines),
             apiKey: (provider == .gemini ? "" : provider == .grok ? grokKey : chatKey).trimmingCharacters(in: .whitespacesAndNewlines),
             side: side, route: provider == .gemini ? .geminiCLI : .http)
    }
}
