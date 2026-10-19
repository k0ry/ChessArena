import Foundation

public enum StageMetrics {
    public static let width = 1920
    public static let height = 1080
}

public struct ModelReply: Equatable, Sendable, Identifiable, Codable {
    public var id: Int
    public var side: Side
    public var name: String
    public var text: String

    public init(id: Int, side: Side, name: String, text: String) {
        self.id = id
        self.side = side
        self.name = name
        self.text = text
    }
}

public struct RequestStatus: Equatable, Sendable, Codable {
    public enum Mode: String, Codable, Sendable { case waiting, retryScheduled, manualPause, preparing }
    public var mode: Mode
    public var attempt: Int
    public var secondsLeft: Int?
    public var reason: String?
    public init(mode: Mode, attempt: Int, secondsLeft: Int? = nil, reason: String? = nil) {
        self.mode = mode; self.attempt = attempt; self.secondsLeft = secondsLeft; self.reason = reason
    }
    public func title(_ language: BroadcastLanguage) -> String {
        switch mode {
        case .waiting: return language.text("ОЖИДАНИЕ ОТВЕТА", "WAITING FOR RESPONSE")
        case .retryScheduled: return language.text("АВТОПОВТОР", "AUTOMATIC RETRY")
        case .manualPause: return language.text("ПАУЗА", "PAUSED")
        case .preparing: return language.text("ХОД ПОЛУЧЕН", "MOVE RECEIVED")
        }
    }
    public func detail(_ language: BroadcastLanguage) -> String {
        switch mode {
        case .waiting:
            return language.text("Ожидание ответа · попытка \(attempt)/3", "Waiting for response · attempt \(attempt)/3")
        case .retryScheduled:
            return language.text("Автоповтор через \(secondsLeft ?? 0) с · попытка \(attempt)/3", "Retry in \(secondsLeft ?? 0) s · attempt \(attempt)/3")
        case .manualPause:
            return reason ?? language.text("Ожидается ручное продолжение.", "Waiting for manual resume.")
        case .preparing:
            return language.text("Готовим озвучку хода…", "Preparing move audio…")
        }
    }
}

public struct BroadcastPicture: Equatable, Sendable, Codable {
    public var whiteName: String
    public var blackName: String
    public var clockText: String
    public var line: String
    public var taunt: String
    public var banner: String?
    public var replies: [ModelReply]
    public var thinkingSide: Side?
    public var pausedPlayer: String?
    public var thinkingSelfNotes: String?
    /// Who delivered the current taunt; absent in older sessions.
    public var tauntSide: Side? = nil
    public var tauntPersona: String? = nil
    /// Whole seconds left before the pending move request times out; nil when nobody is thinking.
    public var thinkSecondsLeft: Int? = nil
    public var requestStatus: RequestStatus? = nil

    public init(
        whiteName: String,
        blackName: String,
        clockText: String,
        line: String,
        taunt: String,
        banner: String?,
        replies: [ModelReply] = [],
        thinkingSide: Side? = nil,
        pausedPlayer: String? = nil,
        thinkingSelfNotes: String? = nil,
        tauntSide: Side? = nil,
        tauntPersona: String? = nil,
        thinkSecondsLeft: Int? = nil,
        requestStatus: RequestStatus? = nil
    ) {
        self.whiteName = whiteName
        self.blackName = blackName
        self.clockText = clockText
        self.line = line
        self.taunt = taunt
        self.banner = banner
        self.replies = replies
        self.thinkingSide = thinkingSide
        self.pausedPlayer = pausedPlayer
        self.thinkingSelfNotes = thinkingSelfNotes
        self.tauntSide = tauntSide
        self.tauntPersona = tauntPersona
        self.thinkSecondsLeft = thinkSecondsLeft
        self.requestStatus = requestStatus
    }

    /// Pending processes/timers are never restored from a saved picture.
    public mutating func clearPendingRequest(language: BroadcastLanguage) {
        if thinkingSide != nil || pausedPlayer != nil || requestStatus != nil {
            line = language.text("Партия сохранена. Продолжите её, чтобы запросить ход.", "Game saved. Resume it to request a move.")
        }
        thinkingSide = nil
        thinkingSelfNotes = nil
        pausedPlayer = nil
        requestStatus = nil
        thinkSecondsLeft = nil
    }

    public static let empty = BroadcastPicture(
        whiteName: "Grok",
        blackName: "ChatGPT",
        clockText: "00:00",
        line: "",
        taunt: "",
        banner: nil
    )

    public var broadcastText: String {
        let spoken = replies.map(\.text).joined(separator: "\n")
        return [whiteName, blackName, clockText, line, taunt, banner ?? "", spoken, thinkingSide == nil ? "" : (thinkingSelfNotes ?? "")].joined(separator: "\n")
    }
}

public enum ClockFormat {
    public static func string(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

public func limitWords(_ text: String, max: Int = 45) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = trimmed.split(whereSeparator: \.isWhitespace)
    guard words.count > max else { return trimmed }
    return words.prefix(max).joined(separator: " ")
}

public enum ReplayPlan {
    public static func steps(sides: [Side]) -> [(ply: Int, tint: String)] {
        var steps: [(Int, String)] = [(0, "none")]
        for (index, side) in sides.enumerated() {
            steps.append((index + 1, side == .white ? "cold" : "amber"))
        }
        return steps
    }
}
