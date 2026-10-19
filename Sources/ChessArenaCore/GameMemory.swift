import Foundation

/// A compact, rolling lesson for each model and color. Contains no account credentials.
public struct GameMemory: Codable, Equatable {
    private struct Entry: Codable, Equatable {
        var endpoint: String
        var model: String
        var side: Side
        var advice: String
        var sourceRoundID: UUID? = nil
    }
    private var entries: [Entry] = []

    public init() {}

    public func advice(for seat: Seat) -> String? {
        entries.first { matches($0, seat) }?.advice
    }

    @MainActor
    public mutating func remember(_ advice: String, for seat: Seat, secrets: [String] = [], sourceRoundID: UUID? = nil) {
        let clean = ModelLog.sanitize(advice, secrets: secrets + [seat.apiKey])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let endpoint = Self.endpoint(seat)
        entries.removeAll { $0.endpoint == endpoint && $0.model == seat.model && $0.side == seat.side }
        entries.append(Entry(endpoint: Self.endpoint(seat), model: seat.model, side: seat.side,
                             advice: String(clean.prefix(4_000)), sourceRoundID: sourceRoundID))
        // Keep storage and prompt size bounded even when experimenting with many models.
        if entries.count > 64 { entries.removeFirst(entries.count - 64) }
    }

    private func matches(_ entry: Entry, _ seat: Seat) -> Bool {
        entry.endpoint == Self.endpoint(seat) && entry.model == seat.model && entry.side == seat.side
    }

    private static func endpoint(_ seat: Seat) -> String {
        var url = URLComponents(url: seat.baseURL, resolvingAgainstBaseURL: false)
        url?.user = nil; url?.password = nil; url?.query = nil; url?.fragment = nil
        return seat.route.rawValue + ":" + (url?.string ?? "")
    }
}
