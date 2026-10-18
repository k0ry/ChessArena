import Foundation

/// Broadcast policy is enforced locally, even if a model ignores the request for silence.
enum BanterPolicy {
    static func randomlyAllowed(draw: Int) -> Bool { (0..<20).contains(draw) }

    /// Call only for a legal move; ordinary captures and castling do not bypass the lottery.
    static func isImportant(_ move: ChessMove, in position: Position) -> Bool {
        let captured = position.piece(at: move.to)?.kind
        let after = position.applying(move)
        return move.promotion != nil || captured == .queen || captured == .rook
            || after.isInCheck(after.sideToMove) || after.terminal() != nil
    }

    static func repeats(_ text: String, recent: [String]) -> Bool {
        func words(_ value: String) -> [String] {
            value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let current = words(text)
        guard !current.isEmpty else { return false }
        return recent.contains {
            let previous = words($0)
            return current == previous || (current.count >= 3 && previous.count >= 3 && current.prefix(3) == previous.prefix(3))
        }
    }

    static func delivery(_ index: Int) -> String {
        let forms = [
            "Make a compact, concrete observation; no setup or analogy.",
            "Use dry understatement; let the implication carry the joke.",
            "Try a brief unexpected comparison, without explaining it.",
            "Use a playful question, without answering it yourself.",
            "Try a tiny scene involving a piece; avoid office or committee metaphors.",
            "Use a contrast between the plan and the visible result, without a stock opening.",
            "Try light self-irony or wordplay, without rhyme or a catchphrase.",
            "Give a crisp factual observation; humor is optional, no forced punchline."
        ]
        return "Delivery suggestion (adapt to the facts; never announce it): " + forms[max(0, index) % forms.count]
    }
}
