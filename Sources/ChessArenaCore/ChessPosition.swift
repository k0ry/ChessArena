import Foundation

public enum Side: String, Equatable, Codable, Sendable {
    case white
    case black

    public var opposite: Side { self == .white ? .black : .white }
    public var fen: String { self == .white ? "w" : "b" }
}

public enum PieceKind: Equatable, Sendable, Codable {
    case pawn, knight, bishop, rook, queen, king

    var fen: Character {
        switch self {
        case .pawn: return "p"
        case .knight: return "n"
        case .bishop: return "b"
        case .rook: return "r"
        case .queen: return "q"
        case .king: return "k"
        }
    }

    var san: String {
        switch self {
        case .pawn: return ""
        case .knight: return "N"
        case .bishop: return "B"
        case .rook: return "R"
        case .queen: return "Q"
        case .king: return "K"
        }
    }

    static func from(fen: Character) -> PieceKind? {
        switch fen.lowercased().first {
        case "p": return .pawn
        case "n": return .knight
        case "b": return .bishop
        case "r": return .rook
        case "q": return .queen
        case "k": return .king
        default: return nil
        }
    }
}

public struct Piece: Equatable, Sendable {
    public var kind: PieceKind
    public var side: Side

    var fen: Character {
        let lower = kind.fen
        return side == .white ? Character(lower.uppercased()) : lower
    }
}

public struct Square: Equatable, Hashable, Sendable, Codable {
    public var file: Int
    public var rank: Int

    public init(file: Int, rank: Int) {
        self.file = file
        self.rank = rank
    }

    public var index: Int { rank * 8 + file }

    public var uci: String {
        let fileChar = Character(UnicodeScalar(97 + file)!)
        return "\(fileChar)\(rank + 1)"
    }

    public init?(uci: String) {
        guard uci.count == 2 else { return nil }
        let chars = Array(uci)
        guard let fileCode = chars[0].asciiValue, let rankCode = chars[1].asciiValue else { return nil }
        let file = Int(fileCode) - 97
        let rank = Int(rankCode) - 49
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        self.file = file
        self.rank = rank
    }

    static func onBoard(file: Int, rank: Int) -> Bool {
        (0..<8).contains(file) && (0..<8).contains(rank)
    }
}

public struct ChessMove: Equatable, Hashable, Sendable, Codable {
    public var from: Square
    public var to: Square
    public var promotion: PieceKind?

    public var uci: String {
        var text = from.uci + to.uci
        if let promotion {
            text.append(promotion.fen)
        }
        return text
    }
}

public struct CastlingRights: Equatable, Sendable {
    public var whiteKing = false
    public var whiteQueen = false
    public var blackKing = false
    public var blackQueen = false

    public var fen: String {
        var text = ""
        if whiteKing { text += "K" }
        if whiteQueen { text += "Q" }
        if blackKing { text += "k" }
        if blackQueen { text += "q" }
        return text.isEmpty ? "-" : text
    }

    static func parse(_ text: String) -> CastlingRights {
        var rights = CastlingRights()
        rights.whiteKing = text.contains("K")
        rights.whiteQueen = text.contains("Q")
        rights.blackKing = text.contains("k")
        rights.blackQueen = text.contains("q")
        return rights
    }
}

public enum Terminal: Equatable, Sendable {
    case checkmate(winner: Side)
    case stalemate
}

public struct Position: Equatable, Sendable {
    public var squares: [Piece?]
    public var sideToMove: Side
    public var castling: CastlingRights
    public var enPassant: Square?
    public var halfmove: Int
    public var fullmove: Int

    public static func standard() -> Position {
        position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")!
    }

    public static func position(fen: String) -> Position? {
        let parts = fen.split(separator: " ")
        guard parts.count >= 4 else { return nil }
        var squares = [Piece?](repeating: nil, count: 64)
        let ranks = parts[0].split(separator: "/")
        guard ranks.count == 8 else { return nil }
        for (rankIndex, rankText) in ranks.enumerated() {
            let rank = 7 - rankIndex
            var file = 0
            for character in rankText {
                if let skip = character.wholeNumberValue {
                    file += skip
                } else if let kind = PieceKind.from(fen: character) {
                    guard file < 8 else { return nil }
                    let side: Side = character.isUppercase ? .white : .black
                    squares[rank * 8 + file] = Piece(kind: kind, side: side)
                    file += 1
                } else {
                    return nil
                }
            }
            guard file == 8 else { return nil }
        }
        let side: Side?
        if parts[1] == "w" {
            side = .white
        } else if parts[1] == "b" {
            side = .black
        } else {
            side = nil
        }
        guard let side else { return nil }
        let ep: Square? = parts[3] == "-" ? nil : Square(uci: String(parts[3]))
        if parts[3] != "-", ep == nil { return nil }
        let half = parts.count > 4 ? Int(parts[4]) ?? 0 : 0
        let full = parts.count > 5 ? Int(parts[5]) ?? 1 : 1
        return Position(
            squares: squares,
            sideToMove: side,
            castling: CastlingRights.parse(String(parts[2])),
            enPassant: ep,
            halfmove: half,
            fullmove: full
        )
    }

    public var fen: String {
        var ranks: [String] = []
        for rankIndex in 0..<8 {
            let rank = 7 - rankIndex
            var text = ""
            var empty = 0
            for file in 0..<8 {
                if let piece = squares[rank * 8 + file] {
                    if empty > 0 {
                        text += "\(empty)"
                        empty = 0
                    }
                    text.append(piece.fen)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { text += "\(empty)" }
            ranks.append(text)
        }
        let ep = enPassant?.uci ?? "-"
        return "\(ranks.joined(separator: "/")) \(sideToMove.fen) \(castling.fen) \(ep) \(halfmove) \(fullmove)"
    }

    public func piece(at square: Square) -> Piece? {
        squares[square.index]
    }

    public func legalMoves() -> [ChessMove] {
        pseudoMoves().filter { !kingExposed(after: $0) }
    }

    public func isLegal(_ move: ChessMove) -> Bool {
        legalMoves().contains(move)
    }

    public func kingSquare(for side: Side) -> Square? {
        for index in 0..<64 {
            if let piece = squares[index], piece.kind == .king, piece.side == side {
                return Square(file: index % 8, rank: index / 8)
            }
        }
        return nil
    }

    public func isInCheck(_ side: Side) -> Bool {
        guard let king = kingSquare(for: side) else { return false }
        return isAttacked(king, by: side.opposite)
    }

    public func terminal() -> Terminal? {
        guard legalMoves().isEmpty else { return nil }
        if isInCheck(sideToMove) {
            return .checkmate(winner: sideToMove.opposite)
        }
        return .stalemate
    }

    public func applying(_ move: ChessMove) -> Position {
        var next = self
        guard let piece = squares[move.from.index] else { return next }
        let captured = squares[move.to.index]
        let isEnPassant = piece.kind == .pawn && move.to == enPassant && captured == nil
        let isCapture = captured != nil || isEnPassant
        next.halfmove = (piece.kind == .pawn || isCapture) ? 0 : halfmove + 1
        next.squares[move.from.index] = nil
        if isEnPassant {
            let capturedPawn = Square(file: move.to.file, rank: move.from.rank)
            next.squares[capturedPawn.index] = nil
        }
        var placed = piece
        if let promotion = move.promotion, piece.kind == .pawn {
            placed.kind = promotion
        }
        next.squares[move.to.index] = placed
        if piece.kind == .king, abs(move.to.file - move.from.file) == 2 {
            let rookFile = move.to.file == 6 ? 7 : 0
            let rookDestination = move.to.file == 6 ? 5 : 3
            let rookFrom = Square(file: rookFile, rank: move.from.rank)
            let rookTo = Square(file: rookDestination, rank: move.from.rank)
            next.squares[rookTo.index] = next.squares[rookFrom.index]
            next.squares[rookFrom.index] = nil
        }
        next.clearCastling(moved: piece, from: move.from)
        if let captured, captured.kind == .rook {
            next.clearRookRight(at: move.to)
        }
        if piece.kind == .pawn, abs(move.to.rank - move.from.rank) == 2 {
            next.enPassant = Square(file: move.from.file, rank: (move.from.rank + move.to.rank) / 2)
        } else {
            next.enPassant = nil
        }
        if piece.side == .black {
            next.fullmove += 1
        }
        next.sideToMove = piece.side.opposite
        return next
    }

    public func san(_ move: ChessMove) -> String {
        guard let piece = squares[move.from.index] else { return move.uci }
        if piece.kind == .king, abs(move.to.file - move.from.file) == 2 {
            return move.to.file > move.from.file ? "O-O" : "O-O-O"
        }
        let capture = squares[move.to.index] != nil || (piece.kind == .pawn && move.to == enPassant)
        var text = ""
        if piece.kind == .pawn {
            if capture { text += String(move.from.uci.prefix(1)) }
        } else {
            text += piece.kind.san
            text += disambiguation(for: move, kind: piece.kind)
        }
        if capture { text += "x" }
        text += move.to.uci
        if let promotion = move.promotion {
            text += "=\(promotion.san)"
        }
        let after = applying(move)
        if after.terminal() == .checkmate(winner: piece.side) {
            text += "#"
        } else if after.isInCheck(after.sideToMove) {
            text += "+"
        }
        return text
    }

    public func parseUCI(_ raw: String) -> ChessMove? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.count == 4 || text.count == 5 else { return nil }
        let chars = Array(text)
        guard let from = Square(uci: String(chars[0...1])),
              let to = Square(uci: String(chars[2...3])) else { return nil }
        var promotion: PieceKind?
        if text.count == 5 {
            promotion = PieceKind.from(fen: chars[4])
            guard promotion != nil, promotion != .pawn, promotion != .king else { return nil }
        } else if let piece = squares[from.index], piece.kind == .pawn {
            let lastRank = piece.side == .white ? 7 : 0
            if to.rank == lastRank { promotion = .queen }
        }
        return ChessMove(from: from, to: to, promotion: promotion)
    }

    private func disambiguation(for move: ChessMove, kind: PieceKind) -> String {
        let peers = legalMoves().filter { candidate in
            guard candidate != move,
                  candidate.to == move.to,
                  let other = squares[candidate.from.index],
                  other.kind == kind,
                  other.side == sideToMove else { return false }
            return true
        }
        guard !peers.isEmpty else { return "" }
        let sameFile = peers.contains { $0.from.file == move.from.file }
        let sameRank = peers.contains { $0.from.rank == move.from.rank }
        if sameFile && sameRank { return move.from.uci }
        if sameFile { return String(move.from.rank + 1) }
        return String(move.from.uci.prefix(1))
    }

    private mutating func clearCastling(moved piece: Piece, from: Square) {
        if piece.kind == .king {
            if piece.side == .white {
                castling.whiteKing = false
                castling.whiteQueen = false
            } else {
                castling.blackKing = false
                castling.blackQueen = false
            }
        }
        if piece.kind == .rook {
            clearRookRight(at: from)
        }
    }

    private mutating func clearRookRight(at square: Square) {
        if square == Square(file: 7, rank: 0) { castling.whiteKing = false }
        if square == Square(file: 0, rank: 0) { castling.whiteQueen = false }
        if square == Square(file: 7, rank: 7) { castling.blackKing = false }
        if square == Square(file: 0, rank: 7) { castling.blackQueen = false }
    }

    private func pseudoMoves() -> [ChessMove] {
        var moves: [ChessMove] = []
        for index in 0..<64 {
            guard let piece = squares[index], piece.side == sideToMove else { continue }
            let square = Square(file: index % 8, rank: index / 8)
            switch piece.kind {
            case .pawn:
                moves.append(contentsOf: pawnMoves(from: square, side: piece.side))
            case .knight:
                moves.append(contentsOf: leapMoves(from: square, side: piece.side, offsets: [(1, 2), (2, 1), (-1, 2), (-2, 1), (1, -2), (2, -1), (-1, -2), (-2, -1)]))
            case .bishop:
                moves.append(contentsOf: slideMoves(from: square, side: piece.side, directions: [(1, 1), (1, -1), (-1, 1), (-1, -1)]))
            case .rook:
                moves.append(contentsOf: slideMoves(from: square, side: piece.side, directions: [(1, 0), (-1, 0), (0, 1), (0, -1)]))
            case .queen:
                moves.append(contentsOf: slideMoves(from: square, side: piece.side, directions: [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]))
            case .king:
                moves.append(contentsOf: leapMoves(from: square, side: piece.side, offsets: [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]))
                moves.append(contentsOf: castlingMoves(from: square, side: piece.side))
            }
        }
        return moves
    }

    private func pawnMoves(from square: Square, side: Side) -> [ChessMove] {
        let direction = side == .white ? 1 : -1
        let startRank = side == .white ? 1 : 6
        var moves: [ChessMove] = []
        let one = Square(file: square.file, rank: square.rank + direction)
        if Square.onBoard(file: one.file, rank: one.rank), squares[one.index] == nil {
            moves.append(contentsOf: promotions(from: square, to: one, side: side))
            if square.rank == startRank {
                let two = Square(file: square.file, rank: square.rank + direction * 2)
                if squares[two.index] == nil {
                    moves.append(ChessMove(from: square, to: two, promotion: nil))
                }
            }
        }
        for fileDelta in [-1, 1] {
            let target = Square(file: square.file + fileDelta, rank: square.rank + direction)
            guard Square.onBoard(file: target.file, rank: target.rank) else { continue }
            if let occupant = squares[target.index], occupant.side != side {
                moves.append(contentsOf: promotions(from: square, to: target, side: side))
            } else if target == enPassant {
                moves.append(ChessMove(from: square, to: target, promotion: nil))
            }
        }
        return moves
    }

    private func promotions(from: Square, to: Square, side: Side) -> [ChessMove] {
        let lastRank = side == .white ? 7 : 0
        guard to.rank == lastRank else {
            return [ChessMove(from: from, to: to, promotion: nil)]
        }
        return [PieceKind.queen, .rook, .bishop, .knight].map {
            ChessMove(from: from, to: to, promotion: $0)
        }
    }

    private func leapMoves(from square: Square, side: Side, offsets: [(Int, Int)]) -> [ChessMove] {
        offsets.compactMap { delta in
            let file = square.file + delta.0
            let rank = square.rank + delta.1
            guard Square.onBoard(file: file, rank: rank) else { return nil }
            let target = Square(file: file, rank: rank)
            if let occupant = squares[target.index], occupant.side == side { return nil }
            return ChessMove(from: square, to: target, promotion: nil)
        }
    }

    private func slideMoves(from square: Square, side: Side, directions: [(Int, Int)]) -> [ChessMove] {
        var moves: [ChessMove] = []
        for direction in directions {
            var file = square.file + direction.0
            var rank = square.rank + direction.1
            while Square.onBoard(file: file, rank: rank) {
                let target = Square(file: file, rank: rank)
                if let occupant = squares[target.index] {
                    if occupant.side != side {
                        moves.append(ChessMove(from: square, to: target, promotion: nil))
                    }
                    break
                }
                moves.append(ChessMove(from: square, to: target, promotion: nil))
                file += direction.0
                rank += direction.1
            }
        }
        return moves
    }

    private func castlingMoves(from square: Square, side: Side) -> [ChessMove] {
        let homeRank = side == .white ? 0 : 7
        guard square == Square(file: 4, rank: homeRank) else { return [] }
        guard !isInCheck(side) else { return [] }
        var moves: [ChessMove] = []
        let kingSide = side == .white ? castling.whiteKing : castling.blackKing
        let queenSide = side == .white ? castling.whiteQueen : castling.blackQueen
        if kingSide,
           squares[Square(file: 5, rank: homeRank).index] == nil,
           squares[Square(file: 6, rank: homeRank).index] == nil,
           !isAttacked(Square(file: 5, rank: homeRank), by: side.opposite),
           !isAttacked(Square(file: 6, rank: homeRank), by: side.opposite) {
            moves.append(ChessMove(from: square, to: Square(file: 6, rank: homeRank), promotion: nil))
        }
        if queenSide,
           squares[Square(file: 1, rank: homeRank).index] == nil,
           squares[Square(file: 2, rank: homeRank).index] == nil,
           squares[Square(file: 3, rank: homeRank).index] == nil,
           !isAttacked(Square(file: 3, rank: homeRank), by: side.opposite),
           !isAttacked(Square(file: 2, rank: homeRank), by: side.opposite) {
            moves.append(ChessMove(from: square, to: Square(file: 2, rank: homeRank), promotion: nil))
        }
        return moves
    }

    private func kingExposed(after move: ChessMove) -> Bool {
        guard let piece = squares[move.from.index] else { return true }
        return applying(move).isInCheck(piece.side)
    }

    private func isAttacked(_ target: Square, by side: Side) -> Bool {
        let pawnDirection = side == .white ? 1 : -1
        for fileDelta in [-1, 1] {
            let file = target.file - fileDelta
            let rank = target.rank - pawnDirection
            if Square.onBoard(file: file, rank: rank),
               let piece = squares[rank * 8 + file],
               piece.side == side, piece.kind == .pawn {
                return true
            }
        }
        let knightOffsets = [(1, 2), (2, 1), (-1, 2), (-2, 1), (1, -2), (2, -1), (-1, -2), (-2, -1)]
        for offset in knightOffsets {
            let file = target.file + offset.0
            let rank = target.rank + offset.1
            if Square.onBoard(file: file, rank: rank),
               let piece = squares[rank * 8 + file],
               piece.side == side, piece.kind == .knight {
                return true
            }
        }
        let kingOffsets = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
        for offset in kingOffsets {
            let file = target.file + offset.0
            let rank = target.rank + offset.1
            if Square.onBoard(file: file, rank: rank),
               let piece = squares[rank * 8 + file],
               piece.side == side, piece.kind == .king {
                return true
            }
        }
        let lines: [(Int, Int, PieceKind, PieceKind)] = [
            (1, 0, .rook, .queen), (-1, 0, .rook, .queen), (0, 1, .rook, .queen), (0, -1, .rook, .queen),
            (1, 1, .bishop, .queen), (1, -1, .bishop, .queen), (-1, 1, .bishop, .queen), (-1, -1, .bishop, .queen),
        ]
        for line in lines {
            var file = target.file + line.0
            var rank = target.rank + line.1
            while Square.onBoard(file: file, rank: rank) {
                if let piece = squares[rank * 8 + file] {
                    if piece.side == side && (piece.kind == line.2 || piece.kind == line.3) {
                        return true
                    }
                    break
                }
                file += line.0
                rank += line.1
            }
        }
        return false
    }
}

public enum GameEnd: Equatable, Sendable, Codable {
    case checkmate(winner: Side)
    case stalemate
    case resignation(loser: Side)

    public var winner: Side? {
        switch self {
        case .checkmate(let winner): return winner
        case .resignation(let loser): return loser.opposite
        case .stalemate: return nil
        }
    }

    public var title: String {
        switch self {
        case .checkmate(let winner):
            return winner == .white ? "CHECKMATE · WHITE" : "CHECKMATE · BLACK"
        case .stalemate:
            return "STALEMATE"
        case .resignation(let loser):
            return loser == .white ? "WHITE RESIGNS" : "BLACK RESIGNS"
        }
    }
}

public struct AcceptedMove: Equatable, Sendable, Codable {
    public var move: ChessMove
    public var san: String
    public var taunt: String
    public var fenAfter: String
}

public enum Submission: Equatable, Sendable {
    case accepted(AcceptedMove, end: GameEnd?)
    case rejected(reason: String, attempt: Int)
    case resigned(GameEnd)
    case ignored
}

public struct Referee: Sendable, Codable, Equatable {
    public private(set) var position: Position
    public private(set) var accepted: [AcceptedMove] = []
    public private(set) var end: GameEnd?
    private var consecutiveFailures = 0

    public init(position: Position = .standard()) {
        self.position = position
        if let terminal = position.terminal() {
            end = terminal == .stalemate ? .stalemate : .checkmate(winner: position.sideToMove.opposite)
        }
    }

    public var legalUCI: [String] {
        position.legalMoves().map(\.uci).sorted()
    }

    public mutating func submit(rawMove: String, taunt: String) -> Submission {
        guard end == nil else { return .ignored }
        if position.terminal() != nil {
            end = position.terminal().map { terminal in
                switch terminal {
                case .checkmate(let winner): return .checkmate(winner: winner)
                case .stalemate: return .stalemate
                }
            }
            return .ignored
        }
        guard let parsed = position.parseUCI(rawMove), position.isLegal(parsed) else {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                let loser = position.sideToMove
                let gameEnd = GameEnd.resignation(loser: loser)
                end = gameEnd
                return .resigned(gameEnd)
            }
            let reason = "Illegal or unreadable move \(rawMove)."
            return .rejected(reason: reason, attempt: consecutiveFailures)
        }
        consecutiveFailures = 0
        let san = position.san(parsed)
        position = position.applying(parsed)
        let gameEnd: GameEnd?
        if let terminal = position.terminal() {
            switch terminal {
            case .checkmate(let winner): gameEnd = .checkmate(winner: winner)
            case .stalemate: gameEnd = .stalemate
            }
            end = gameEnd
        } else {
            gameEnd = nil
        }
        let record = AcceptedMove(move: parsed, san: san, taunt: taunt, fenAfter: position.fen)
        accepted.append(record)
        return .accepted(record, end: gameEnd)
    }
}

// FEN retains castling rights, en passant and both move counters.
extension Position: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        let fen = try value.decode(String.self)
        guard let position = Position.position(fen: fen), position.halfmove >= 0, position.fullmove >= 1,
              position.squares.compactMap({ $0 }).filter({ $0.kind == .king && $0.side == .white }).count == 1,
              position.squares.compactMap({ $0 }).filter({ $0.kind == .king && $0.side == .black }).count == 1 else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid saved chess position")
        }
        self = position
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(fen)
    }
}
