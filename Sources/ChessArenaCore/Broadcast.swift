import Foundation

public enum StageMetrics {
    public static let width = 1920
    public static let height = 1080
}

public struct ModelReply: Equatable, Sendable, Identifiable {
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

public struct BroadcastPicture: Equatable, Sendable {
    public var whiteName: String
    public var blackName: String
    public var clockText: String
    public var line: String
    public var taunt: String
    public var banner: String?
    public var replies: [ModelReply]
    public var thinkingSide: Side?
    public var pausedPlayer: String?

    public init(
        whiteName: String,
        blackName: String,
        clockText: String,
        line: String,
        taunt: String,
        banner: String?,
        replies: [ModelReply] = [],
        thinkingSide: Side? = nil,
        pausedPlayer: String? = nil
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
        return [whiteName, blackName, clockText, line, taunt, banner ?? "", spoken].joined(separator: "\n")
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
