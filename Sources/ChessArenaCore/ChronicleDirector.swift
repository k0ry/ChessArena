import Foundation

/// Keeps the live game uninterrupted and shows the result only after game over.
public struct ChronicleDirector: Sendable {
    public enum Phase: Equatable, Sendable {
        case live
        case finalCard(endsAt: TimeInterval)
        case done
    }

    public enum Cue: Equatable, Sendable {
        case startFinal
        case endFinal
    }

    public var gameOver = false
    public private(set) var now: TimeInterval = 0
    public private(set) var phase: Phase = .live
    public static let duration: TimeInterval = MatchSeries.intermission

    public init() {}

    public mutating func advance(to time: TimeInterval) -> [Cue] {
        now = time
        switch phase {
        case .live:
            guard gameOver else { return [] }
            phase = .finalCard(endsAt: time + Self.duration)
            return [.startFinal]
        case .finalCard(let endsAt):
            guard time >= endsAt else { return [] }
            phase = .done
            return [.endFinal]
        case .done:
            return []
        }
    }
}
