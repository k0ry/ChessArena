import AVFoundation
import Foundation

enum SpokenText {
    /// Models occasionally return another layer of JSON escaping inside their text.
    /// Clean only broadcast speech; preserve the original response in the model log.
    static func clean(_ source: String) -> String {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapes = try! NSRegularExpression(pattern: #"(?:\\u[0-9a-fA-F]{4})+|\\["\\/bfnrt]"#)
        for _ in 0..<3 {
            if let decoded = try? JSONDecoder().decode(String.self, from: Data(text.utf8)) {
                text = decoded
            }
            let matches = escapes.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: text) else { continue }
                let token = String(text[range])
                if let decoded = try? JSONDecoder().decode(String.self, from: Data(("\"" + token + "\"").utf8)) {
                    text.replaceSubrange(range, with: decoded)
                }
            }
        }
        // Some replies spell out the escape name or use HTML/Unicode variants.
        // None of these formatting artifacts belong in chess broadcast speech.
        text = text.replacingOccurrences(of: #"(?i)&(?:bsol|#0*92|#x0*5c);"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)(?<![\p{L}\p{N}_])(?:back[\s-]*slash(?:es)?|б[еэ]к[\s-]*сл[еэ]ш(?:и|ей|а|ем|у)?)(?![\p{L}\p{N}_])"#,
                                        with: " ", options: .regularExpression)
        return text.replacingOccurrences(of: #"[\\＼﹨∖⧵⧹]"#, with: " ", options: .regularExpression)
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?;:…])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SpeechKind: String, Equatable, Sendable {
    case tone
    case intro
    case taunt
    case move
    case wait
    case resignation
    case stall
    case chronicle
    case final
}

public struct SpokenLine: Equatable, Sendable {
    public var kind: SpeechKind
    public var text: String
    public var boardVersion: Int
    public var clock: TimeInterval
}

/// Who is speaking: the ring-announcer host or a player's comedic persona. Describes delivery, never a real voice to clone.
public enum VoiceProfile: Equatable, Sendable {
    case host
    case persona(PlayerPersona)

    /// Installed-voice names in order of preference; the first installed one wins, then any male voice, then the default.
    public func preferredVoiceNames(for language: BroadcastLanguage) -> [String] {
        if language == .russian { return ["Yuri", "Dmitry", "Milena"] }
        switch self {
        case .host: return ["Daniel", "Reed", "Rocko", "Fred"]
        case .persona(let persona):
            switch persona {
            case .carrey: return ["Eddy", "Rocko", "Reed"]
            case .pryor: return ["Reed", "Fred", "Daniel"]
            case .carlin: return ["Fred", "Ralph", "Reed"]
            case .chappelle: return ["Rocko", "Eddy", "Reed"]
            case .louisCK: return ["Ralph", "Fred", "Daniel"]
            case .burr: return ["Reed", "Daniel", "Rocko"]
            case .gervais: return ["Daniel", "Reed", "Eddy"]
            case .burnham: return ["Eddy", "Rocko", "Daniel"]
            }
        }
    }

    /// Pitch multiplier: the host sits low like a boxing announcer; personas spread around neutral.
    public var pitch: Float {
        switch self {
        case .host: return 0.78
        case .persona(let persona):
            switch persona {
            case .carrey: return 1.15
            case .pryor: return 0.95
            case .carlin: return 0.9
            case .chappelle: return 0.92
            case .louisCK: return 0.85
            case .burr: return 1.0
            case .gervais: return 1.05
            case .burnham: return 1.1
            }
        }
    }

    /// Speech rate around the system default (0.5): slow and weighty for the host, fast for the manic personas.
    public var rate: Float {
        switch self {
        case .host: return 0.42
        case .persona(let persona):
            switch persona {
            case .carrey: return 0.58
            case .pryor: return 0.5
            case .carlin: return 0.47
            case .chappelle: return 0.44
            case .louisCK: return 0.43
            case .burr: return 0.55
            case .gervais: return 0.48
            case .burnham: return 0.53
            }
        }
    }

    public var pauseBefore: TimeInterval { self == .host ? 0.3 : 0.15 }
}

/// A platform-independent view of an installed voice, so voice selection is testable without the synthesizer.
public struct VoiceDescriptor: Equatable, Sendable {
    public var identifier: String
    public var name: String
    public var language: String
    public var isMale: Bool
    public init(identifier: String, name: String, language: String, isMale: Bool) {
        self.identifier = identifier; self.name = name; self.language = language; self.isMale = isMale
    }
}

public enum VoiceSelection {
    /// Language match by prefix ("ru" matches "ru-RU"), preferred names first, then any male voice, then nil (system default).
    public static func pick(for profile: VoiceProfile, language: BroadcastLanguage, from voices: [VoiceDescriptor]) -> VoiceDescriptor? {
        let prefix = language.rawValue.prefix(2).lowercased()
        let candidates = voices.filter { $0.language.lowercased().hasPrefix(prefix) }
        for name in profile.preferredVoiceNames(for: language) {
            if let match = candidates.first(where: { $0.name.lowercased().hasPrefix(name.lowercased()) && ($0.isMale || name == "Milena") }) {
                if match.isMale { return match }
            }
        }
        return candidates.first(where: \.isMale)
    }

    public static func hasMaleVoice(for language: BroadcastLanguage, in voices: [VoiceDescriptor]) -> Bool {
        let prefix = language.rawValue.prefix(2).lowercased()
        return voices.contains { $0.language.lowercased().hasPrefix(prefix) && $0.isMale }
    }
}

@MainActor
public protocol Voice: AnyObject {
    var language: BroadcastLanguage { get set }
    func stop()
    var isSpeaking: Bool { get }
    func prepare(_ text: String, kind: SpeechKind, profile: VoiceProfile) async -> PreparedSpeech
    func play(_ speech: PreparedSpeech, onStart: @escaping @MainActor () -> Void) async -> [Int16]
}

extension Voice {
    public func speak(_ text: String, kind: SpeechKind, profile: VoiceProfile) async -> [Int16] {
        let speech = await prepare(text, kind: kind, profile: profile)
        guard !Task.isCancelled else { return [] }
        return await play(speech, onStart: {})
    }
}

@MainActor
public final class ScriptedVoice: Voice {
    public var language: BroadcastLanguage = .english
    public func stop() { release(); releasePreparation() }
    public private(set) var isSpeaking = false
    public var lines: [SpokenLine] = []
    /// Every utterance with its profile, in order, for tests.
    public private(set) var spoken: [(text: String, kind: SpeechKind, profile: VoiceProfile)] = []
    public var hold = false
    private var waiter: CheckedContinuation<Void, Never>?
    public var onSpeaking: (() -> Void)?
    public private(set) var prepared: [PreparedSpeech] = []
    public var holdPreparation = false
    private var preparationWaiter: CheckedContinuation<Void, Never>?

    public init() {}

    public func prepare(_ text: String, kind: SpeechKind, profile: VoiceProfile) async -> PreparedSpeech {
        let speech = PreparedSpeech(text: text, kind: kind, profile: profile, samples: Array(repeating: 1200, count: 4410))
        prepared.append(speech)
        if holdPreparation {
            await withTaskCancellationHandler {
                await withCheckedContinuation { preparationWaiter = $0 }
            } onCancel: { Task { @MainActor in self.releasePreparation() } }
        }
        return speech
    }

    public func releasePreparation() { preparationWaiter?.resume(); preparationWaiter = nil }

    public func play(_ speech: PreparedSpeech, onStart: @escaping @MainActor () -> Void) async -> [Int16] {
        guard !Task.isCancelled else { return [] }
        spoken.append((speech.text, speech.kind, speech.profile))
        isSpeaking = true
        onStart()
        onSpeaking?()
        if hold {
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter = $0 }
            } onCancel: { Task { @MainActor in self.release() } }
        }
        isSpeaking = false
        return Task.isCancelled ? [] : speech.samples
    }

    public func release() {
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
public final class SystemVoice: NSObject, Voice {
    public var language: BroadcastLanguage = .russian
    public private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private let audioPlayer = PreparedAudioPlayer()
    private let synthesisGate = SpeechGate()
    private let playbackGate = SpeechGate()
    private var generation = UUID()
    private var utteranceID = UUID()
    private var continuation: CheckedContinuation<[Int16], Never>?
    private var samples: [Int16] = []

    public func stop() {
        generation = UUID()
        cancelSynthesis()
        synthesisGate.cancelPending(); playbackGate.cancelPending()
        audioPlayer.stop()
        isSpeaking = false
    }

    private func cancelSynthesis() {
        utteranceID = UUID()
        synthesizer.stopSpeaking(at: .immediate)
        let waiting = continuation; continuation = nil
        waiting?.resume(returning: [])
    }

    public func prepare(_ text: String, kind: SpeechKind, profile: VoiceProfile) async -> PreparedSpeech {
        var speech = PreparedSpeech(text: SpokenText.clean(text), kind: kind, profile: profile, samples: [])
        let epoch = generation
        guard await synthesisGate.acquire() else { return speech }
        defer { synthesisGate.release() }
        guard epoch == generation, !Task.isCancelled,
              let utterance = Self.makeUtterance(text, language: language, profile: profile) else { return speech }
        let id = UUID(); utteranceID = id
        samples = []
        speech.samples = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: []); return }
                self.continuation = continuation
                synthesizer.write(utterance) { [weak self] buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    // Copy before crossing actors: the synthesizer may reuse the source buffer.
                    let chunk = Self.int16Samples(from: pcm)
                    let rate = pcm.format.sampleRate
                    let finished = pcm.frameLength == 0
                    Task { @MainActor [weak self] in
                        guard let self, self.utteranceID == id else { return }
                        if finished {
                            let waiting = self.continuation; self.continuation = nil
                            waiting?.resume(returning: self.samples)
                        } else {
                            self.samples.append(contentsOf: AudioSamples.resample(chunk, from: rate))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.utteranceID == id { self?.cancelSynthesis() }
            }
        }
        return speech
    }

    public func play(_ speech: PreparedSpeech, onStart: @escaping @MainActor () -> Void) async -> [Int16] {
        let epoch = generation
        guard await playbackGate.acquire() else { return [] }
        defer { playbackGate.release() }
        guard epoch == generation, !Task.isCancelled else { return [] }
        isSpeaking = true
        defer { if epoch == generation { isSpeaking = false } }
        return await audioPlayer.play(speech.samples, onStart: onStart)
    }

    /// The last boundary before AVSpeechSynthesizer, including direct sound checks.
    static func makeUtterance(_ text: String, language: BroadcastLanguage, profile: VoiceProfile = .host) -> AVSpeechUtterance? {
        let spoken = SpokenText.clean(text)
        guard !spoken.isEmpty else { return nil }
        let utterance = AVSpeechUtterance(string: spoken)
        if let picked = VoiceSelection.pick(for: profile, language: language, from: installedVoices()),
           let voice = AVSpeechSynthesisVoice(identifier: picked.identifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        }
        utterance.pitchMultiplier = profile.pitch
        utterance.rate = profile.rate
        utterance.preUtteranceDelay = profile.pauseBefore
        return utterance
    }

    public static func installedVoices() -> [VoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map {
            VoiceDescriptor(identifier: $0.identifier, name: $0.name, language: $0.language, isMale: $0.gender == .male)
        }
    }

    /// Whether the language of the broadcast has any installed male voice for the announcer.
    public static func hasMaleVoice(for language: BroadcastLanguage) -> Bool {
        VoiceSelection.hasMaleVoice(for: language, in: installedVoices())
    }

    nonisolated private static func int16Samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        if let channel = buffer.int16ChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: frames))
        }
        guard let channel = buffer.floatChannelData else { return [] }
        return UnsafeBufferPointer(start: channel[0], count: frames).map {
            Int16(max(-1, min(1, $0)) * 32767)
        }
    }
}
