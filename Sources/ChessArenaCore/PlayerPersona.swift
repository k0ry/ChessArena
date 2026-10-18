import Foundation

/// A comedic manner for a player's taunts. Describes delivery and humor, never a voice to clone or a person to impersonate.
public enum PlayerPersona: String, CaseIterable, Codable, Sendable {
    case carrey, pryor, carlin, chappelle, louisCK, burr, gervais, burnham

    public func displayName(_ language: BroadcastLanguage) -> String {
        switch self {
        case .carrey: return language.text("Эксцентрик", "Eccentric")
        case .pryor: return language.text("Рассказчик", "Storyteller")
        case .carlin: return language.text("Сатирик", "Satirist")
        case .chappelle: return language.text("Иронист", "Ironist")
        case .louisCK: return language.text("Скептик", "Skeptic")
        case .burr: return language.text("Спорщик", "Challenger")
        case .gervais: return language.text("Острослов", "Dry wit")
        case .burnham: return language.text("Абсурдист", "Absurdist")
        }
    }

    /// Manner of the taunt for the player's system prompt.
    public var instruction: String {
        let manner: String
        switch self {
        case .carrey:
            manner = "manic, rubber-faced energy: sudden mood swings, exaggerated mock-amazement, cartoonish imagery and a gleeful jab delivered at full speed."
        case .pryor:
            manner = "confessional streetwise storytelling: disarming honesty about your own nerves, then a sharp turn that exposes the opponent's bluff, warm but merciless."
        case .carlin:
            manner = "incisive observational satire: expose the gap between the opponent's grand label and the ordinary reality on the board, with a compact logical reversal."
        case .chappelle:
            manner = "laid-back provocation: a relaxed setup, a knowing pause, then an unexpectedly pointed observation about what the opponent just did."
        case .louisCK:
            manner = "tired, cynical self-deprecation that curdles into contempt for the opponent's choice; weary sighs, mundane comparisons, bleak honesty."
        case .burr:
            manner = "blunt, irritated, no apologies: short punchy clauses, exasperation at the obvious, a direct call-out of the opponent's nonsense."
        case .gervais:
            manner = "polite British cruelty: a smiling compliment that is actually a demolition, dry understatement, mock sympathy for the opponent."
        case .burnham:
            manner = "theatrical, wordplay-heavy self-aware wit: a rhyme or a twisted idiom, a nod to the absurdity of two machines trash-talking over chess."
        }
        return "Taunt persona: deliver the taunt with \(manner) Use this as a loose palette, not a fixed setup or catchphrase. If a taunt is allowed, address it to your opponent as one short sentence. "
            + "Stay original: no quotations or catchphrases, never name or claim to be any real person, no slurs, no profanity, "
            + "no remarks about anyone's identity. The persona changes only the taunt, never the move or the output format."
    }
}

/// Which persona each model plays. Keyed by provider and model, independent of color and endpoint.
public struct PersonaAssignments: Codable, Equatable, Sendable {
    public private(set) var entries: [String: PlayerPersona]

    public init(entries: [String: PlayerPersona] = [:]) { self.entries = entries }

    /// Drawn at random on 17 October 2026 for the models already in use; seeds an empty table.
    public static let initial = PersonaAssignments(entries: [
        key(provider: .grok, model: ModelCatalog.grokModel): .louisCK,
        key(provider: .chatGPT, model: ModelCatalog.chatGPTModel): .burr,
        key(provider: .gemini, model: GeminiCLI.defaultModel): .carlin,
        key(provider: .claude, model: ModelCatalog.claudeModel): .gervais,
    ])

    public static func key(provider: NeuralProvider, model: String) -> String {
        provider.rawValue + "|" + model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func persona(provider: NeuralProvider, model: String) -> PlayerPersona? {
        entries[Self.key(provider: provider, model: model)]
    }

    /// Returns the assigned persona, assigning a random free one on first encounter.
    @discardableResult
    public mutating func assign(provider: NeuralProvider, model: String) -> PlayerPersona {
        var generator = SystemRandomNumberGenerator()
        return assign(provider: provider, model: model, using: &generator)
    }

    @discardableResult
    public mutating func assign<G: RandomNumberGenerator>(provider: NeuralProvider, model: String, using generator: inout G) -> PlayerPersona {
        let key = Self.key(provider: provider, model: model)
        if let existing = entries[key] { return existing }
        let taken = Set(entries.values)
        let free = PlayerPersona.allCases.filter { !taken.contains($0) }
        let pool = free.isEmpty ? PlayerPersona.allCases : free
        let chosen = pool.randomElement(using: &generator) ?? .carlin
        entries[key] = chosen
        return chosen
    }
}
