import Foundation

public enum BroadcastLanguage: String, CaseIterable, Identifiable, Sendable, Codable {
    case russian = "ru-RU"
    case english = "en-US"
    public var id: String { rawValue }
    public var name: String { self == .russian ? "Русский" : "English" }
    public func text(_ russian: String, _ english: String) -> String { self == .russian ? russian : english }
    public var toneTest: String { text("Проверка звука. Фигуры готовы — начинаем шахматный бой!", ModelCatalog.toneTest) }
    public func prompt(_ system: String) -> String {
        system.replacingOccurrences(of: "English", with: self == .russian ? "Russian" : "English")
            + " Use only \(self == .russian ? "Russian" : "English") for spoken commentary and taunts. Keep structured output and chess notation unchanged."
    }
    public func result(_ end: GameEnd, white: String, black: String) -> String {
        guard let winner = end.winner else { return text("ПАТ · НИЧЬЯ", "STALEMATE · DRAW") }
        let name = winner == .white ? white : black
        return text("МАТ · \(name) ПОБЕЖДАЕТ", "CHECKMATE · \(name) WINS")
    }
}

public struct SeriesScore: Codable, Equatable, Sendable {
    public private(set) var whiteHalfPoints = 0
    public private(set) var blackHalfPoints = 0
    public private(set) var games = 0
    public init() {}
    public var white: String { Self.format(whiteHalfPoints) }
    public var black: String { Self.format(blackHalfPoints) }
    private static func format(_ half: Int) -> String { half.isMultiple(of: 2) ? "\(half / 2)" : "\(half / 2)½" }
    public mutating func record(_ end: GameEnd, position: Position) {
        guard position.gameEnd == end else { return }
        games += 1
        whiteHalfPoints += end.winner == .white ? 2 : (end.winner == nil ? 1 : 0)
        blackHalfPoints += end.winner == .black ? 2 : (end.winner == nil ? 1 : 0)
    }
    /// Undo only the one invalid result explicitly attached to a legacy round.
    mutating func undoLegacyResult(_ end: GameEnd) {
        let white = end.winner == .white ? 2 : (end.winner == nil ? 1 : 0)
        let black = end.winner == .black ? 2 : (end.winner == nil ? 1 : 0)
        guard games > 0, whiteHalfPoints >= white, blackHalfPoints >= black else { return }
        games -= 1; whiteHalfPoints -= white; blackHalfPoints -= black
    }

}

/// Owns round identity, exactly-once scoring and the restart deadline independently of API/voice work.
public struct MatchSeries: Codable {
    public static let intermission: TimeInterval = 30
    public private(set) var score: SeriesScore
    public private(set) var running = false
    public private(set) var roundID: UUID?
    public private(set) var result: GameEnd?
    public private(set) var restartAt: TimeInterval?
    public init(score: SeriesScore = SeriesScore()) { self.score = score }
    public mutating func start() -> UUID {
        running = true
        return beginRound()
    }
    /// Resume an unfinished round without replacing its identity or scoring it again.
    public mutating func resumeRound() -> UUID? {
        guard result == nil else { return nil }
        running = true
        restartAt = nil
        if let roundID { return roundID }
        return beginRound()
    }
    public mutating func startNewSeries() -> UUID {
        score = SeriesScore()
        return start()
    }
    private mutating func beginRound() -> UUID {
        let id = UUID()
        roundID = id; result = nil; restartAt = nil
        return id
    }
    @discardableResult
    public mutating func complete(round: UUID, result: GameEnd, position: Position, now: TimeInterval, startIntermission: Bool = true) -> Bool {
        guard running, roundID == round, self.result == nil, position.gameEnd == result else { return false }
        self.result = result
        score.record(result, position: position)
        restartAt = startIntermission ? now + Self.intermission : nil
        return true
    }
    @discardableResult
    public mutating func beginIntermission(round: UUID, now: TimeInterval) -> Bool {
        guard running, roundID == round, result != nil, restartAt == nil else { return false }
        restartAt = now + Self.intermission
        return true
    }
    public func remaining(at now: TimeInterval) -> Int? {
        restartAt.map { max(0, Int(ceil($0 - now))) }
    }
    public mutating func nextRoundIfDue(at now: TimeInterval) -> UUID? {
        guard running, let deadline = restartAt, now >= deadline else { return nil }
        return beginRound()
    }
    @discardableResult
    public mutating func recoverLegacyResult(position: Position) -> Bool {
        guard let result, result != position.gameEnd else { return false }
        score.undoLegacyResult(result)
        self.result = nil
        stop()
        return true
    }
    public mutating func stop() { running = false; restartAt = nil }
}
