import Foundation

public struct ChronicleDirector: Sendable {
    public enum Phase: Equatable, Sendable {
        case live
        case chronicle(mark: TimeInterval, endsAt: TimeInterval, voiceReady: Bool)
        case finalCard(endsAt: TimeInterval)
        case done
    }

    public enum Cue: Equatable, Sendable {
        case prepare(TimeInterval)
        case startChronicle(TimeInterval)
        case startVoice(String)
        case endChronicle
        case startFinal
        case endFinal
    }

    public var blocked = false
    public var gameOver = false
    public private(set) var now: TimeInterval = 0
    public private(set) var nextMark: TimeInterval = 300
    public private(set) var phase: Phase = .live
    public static let duration: TimeInterval = 14
    public static let lead: TimeInterval = 40

    private var prepared = Set<TimeInterval>()

    public init() {}

    public mutating func advance(to time: TimeInterval, voiceText: String?) -> [Cue] {
        now = time
        var cues: [Cue] = []

        if case .chronicle(let mark, let endsAt, let voiceReady) = phase {
            if !voiceReady, let voiceText, time < endsAt {
                phase = .chronicle(mark: mark, endsAt: endsAt, voiceReady: true)
                cues.append(.startVoice(limitWords(voiceText)))
            }
            if time >= endsAt {
                cues.append(.endChronicle)
                phase = .live
            } else {
                return cues
            }
        }

        if case .finalCard(let endsAt) = phase {
            if time >= endsAt {
                phase = .done
                cues.append(.endFinal)
            }
            return cues
        }
        if case .done = phase {
            return cues
        }

        if gameOver {
            phase = .finalCard(endsAt: time + Self.duration)
            cues.append(.startFinal)
            return cues
        }

        if time >= nextMark - Self.lead, !prepared.contains(nextMark) {
            prepared.insert(nextMark)
            cues.append(.prepare(nextMark))
        }
        if time >= nextMark, !blocked {
            let mark = nextMark
            nextMark += 300
            let ready = voiceText != nil
            phase = .chronicle(mark: mark, endsAt: time + Self.duration, voiceReady: ready)
            cues.append(.startChronicle(mark))
            if let voiceText {
                cues.append(.startVoice(limitWords(voiceText)))
            }
        }
        return cues
    }
}
