import Foundation

public enum NeuralProvider: String, CaseIterable, Identifiable, Sendable {
    case grok = "Grok"
    case chatGPT = "ChatGPT"

    public var id: String { rawValue }
    public var defaultModel: String {
        self == .grok ? ModelCatalog.grokModel : ModelCatalog.chatGPTModel
    }
    public var baseURL: URL {
        self == .grok ? ModelCatalog.grokAPI : ModelCatalog.openAIAPI
    }
}

public struct PlayerConfiguration: Equatable, Sendable {
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
             apiKey: (provider == .grok ? grokKey : chatKey).trimmingCharacters(in: .whitespacesAndNewlines),
             side: side)
    }
}
