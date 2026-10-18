import Foundation

/// Stable defaults keyed by persona, independent of enum/catalog order.
public struct QwenVoiceCasting: Equatable, Sendable {
    public private(set) var entries: [String: String]

    public init(entries: [String: String] = [:]) {
        self.entries = entries.filter {
            PlayerPersona(rawValue: $0.key) != nil && LocalQwenConfiguration.voices.contains($0.value)
        }
    }

    public func voice(for persona: PlayerPersona) -> String {
        if let voice = entries[persona.rawValue] { return voice }
        switch persona {
        case .carrey: return "Dylan"
        case .pryor: return "Aiden"
        case .carlin: return "Uncle_Fu"
        case .chappelle: return "Serena"
        case .louisCK: return "Eric"
        case .burr: return "Vivian"
        case .gervais: return "Sohee"
        case .burnham: return "Ono_Anna"
        }
    }

    public mutating func setVoice(_ voice: String, for persona: PlayerPersona) {
        guard LocalQwenConfiguration.voices.contains(voice) else { return }
        entries[persona.rawValue] = voice
    }
}

extension VoiceProfile {
    /// Vocal direction only: no real person's name or instruction to imitate a voice.
    public var neuralDelivery: String {
        let delivery: String
        switch self {
        case .host:
            delivery = "Deep, resonant ring announcer delivery. Speak slowly and confidently, with clear pauses between phrases."
        case .persona(.carrey):
            delivery = "Energetic and playful. Quick, clear speech with exaggerated surprise and lively changes of intonation."
        case .persona(.pryor):
            delivery = "Warm conversational storytelling. Relaxed rhythm, then a sharp emphasis on the final punchline."
        case .persona(.carlin):
            delivery = "Dry, thoughtful irony. Measured pace, precise articulation, stress the contrast in the sentence."
        case .persona(.chappelle):
            delivery = "Calm and laid-back. Unhurried speech with a knowing pause before the last few words."
        case .persona(.louisCK):
            delivery = "Weary, understated self-deprecation. Low energy, slow pace, a resigned but intelligible ending."
        case .persona(.burr):
            delivery = "Brisk, exasperated and assertive. Short punchy phrases with emphatic consonants. Do not shout."
        case .persona(.gervais):
            delivery = "Polite, smiling sarcasm. Crisp diction, restrained amusement and a dry, gently mocking finish."
        case .persona(.burnham):
            delivery = "Theatrical, rhythmic and self-aware. Playful emphasis on wordplay, a clear dramatic pause. Speak, do not sing."
        }
        return delivery + " Use an original voice; do not impersonate any real person."
    }

    public func previewText(_ language: BroadcastLanguage) -> String {
        if self == .host { return language.toneTest }
        return language.text("Конь выходит на эф три. Красивый план, но центр уже мой!",
                             "The knight moves to f three. Nice plan, but the center is already mine!")
    }
}
