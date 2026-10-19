import ChessArenaCore

func terminalBoard(_ result: GameEnd) -> Position {
    let fen: String
    switch result {
    case .checkmate(winner: .white): fen = "7k/6Q1/5K2/8/8/8/8/8 b - - 0 1"
    case .checkmate(winner: .black): fen = "8/8/8/8/8/5k2/6q1/7K w - - 0 1"
    default: fen = "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"
    }
    return Position.position(fen: fen)!
}
