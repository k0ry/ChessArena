import XCTest
@testable import ChessArenaCore

final class RefereeTests: XCTestCase {
    func testHistoricalFalseLossPositionsRemainPlayableAfterHundredFailures() {
        for (fen, count) in [
            ("r2q1rk1/1p1nbppp/p2pbn2/4p3/4P3/1NN1BP2/PPPQ2PP/2KR1B1R w - - 5 11", 40),
            ("r2q1rk1/3nbppp/p2pb3/4p1Pn/1p2P3/1N2BP2/PPPQN2P/2KR1B1R w - - 2 14", 36),
            ("r1b1k2r/1pqnbppp/p2ppn2/6B1/3NPP2/2N2Q2/PPP3PP/2KR1B1R w kq - 5 10", 43)
        ] {
            var referee = Referee(position: Position.position(fen: fen)!)
            XCTAssertEqual(referee.legalUCI.count, count)
            for index in 1...100 {
                guard case .rejected = referee.submit(rawMove: index.isMultiple(of: 2) ? "" : "a1a8", taunt: "") else { return XCTFail("Unexpected result") }
                XCTAssertNil(referee.end)
                XCTAssertEqual(referee.position.fen, fen)
            }
        }
    }

    func testInitialPositionHasTwentyLegalMovesAndRoundTripsFEN() {
        let position = Position.standard()
        XCTAssertEqual(position.legalMoves().count, 20)
        XCTAssertEqual(position.fen, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
        XCTAssertEqual(Position.position(fen: position.fen)?.fen, position.fen)
    }

    func testLegalOpeningMoveUpdatesTheBoardAndIllegalMoveDoesNot() {
        var referee = Referee()
        let before = referee.position.fen
        let rejected = referee.submit(rawMove: "e2e5", taunt: "no")
        guard case .rejected = rejected else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(referee.position.fen, before)
        XCTAssertTrue(referee.accepted.isEmpty)

        let accepted = referee.submit(rawMove: "e2e4", taunt: "after you")
        guard case .accepted(let move, let end) = accepted else {
            return XCTFail("expected acceptance")
        }
        XCTAssertNil(end)
        XCTAssertEqual(move.move.uci, "e2e4")
        XCTAssertEqual(move.san, "e4")
        XCTAssertEqual(referee.position.piece(at: Square(uci: "e4")!)?.kind, .pawn)
        XCTAssertNil(referee.position.piece(at: Square(uci: "e2")!))
        XCTAssertEqual(referee.position.sideToMove, .black)
    }

    func testCastlingEnPassantAndDefaultQueenPromotion() {
        var position = Position.standard()
        let setup = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "e1g1"]
        for uci in setup {
            let move = position.parseUCI(uci)!
            XCTAssertTrue(position.isLegal(move), uci)
            position = position.applying(move)
        }
        XCTAssertEqual(position.piece(at: Square(uci: "g1")!)?.kind, .king)
        XCTAssertEqual(position.piece(at: Square(uci: "f1")!)?.kind, .rook)

        var ep = Position.standard()
        for uci in ["e2e4", "a7a6", "e4e5", "d7d5"] {
            ep = ep.applying(ep.parseUCI(uci)!)
        }
        let capture = ep.parseUCI("e5d6")!
        XCTAssertTrue(ep.legalMoves().contains(capture))
        ep = ep.applying(capture)
        XCTAssertEqual(ep.piece(at: Square(uci: "d6")!)?.kind, .pawn)
        XCTAssertEqual(ep.piece(at: Square(uci: "d6")!)?.side, .white)
        XCTAssertNil(ep.piece(at: Square(uci: "d5")!))

        let promo = Position.position(fen: "8/P7/8/8/8/8/8/4K2k w - - 0 1")!
        let implied = promo.parseUCI("a7a8")!
        XCTAssertEqual(implied.promotion, .queen)
        XCTAssertTrue(promo.isLegal(implied))
        let queened = promo.applying(implied)
        XCTAssertEqual(queened.piece(at: Square(uci: "a8")!)?.kind, .queen)
        let knight = promo.parseUCI("a7a8n")!
        XCTAssertTrue(promo.isLegal(knight))
        XCTAssertEqual(promo.applying(knight).piece(at: Square(uci: "a8")!)?.kind, .knight)
    }

    func testKingsideCastleSANAfterThePathIsClear() {
        var position = Position.standard()
        for uci in ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6"] {
            position = position.applying(position.parseUCI(uci)!)
        }
        let castle = position.parseUCI("e1g1")!
        XCTAssertTrue(position.isLegal(castle))
        XCTAssertEqual(position.san(castle), "O-O")
    }

    func testErrorsNeverEndGameAndMateOrStalemateEndsWithoutAnotherRequest() {
        var referee = Referee()
        for attempt in 1...100 {
            XCTAssertEqual(referee.submit(rawMove: "", taunt: ""), .rejected(reason: "Illegal or unreadable move .", attempt: attempt))
            XCTAssertNil(referee.end)
            XCTAssertEqual(referee.position, .standard())
        }
        guard case .accepted = referee.submit(rawMove: "e2e4", taunt: "") else { return XCTFail("Must recover") }

        var mate = Referee()
        for uci in ["f2f3", "e7e5", "g2g4", "d8h4"] {
            _ = mate.submit(rawMove: uci, taunt: "")
        }
        XCTAssertEqual(mate.end, .checkmate(winner: .black))
        XCTAssertEqual(mate.submit(rawMove: "e2e3", taunt: ""), .ignored)

        let stale = Position.position(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")!
        XCTAssertEqual(stale.terminal(), .stalemate)
        var staleReferee = Referee(position: stale)
        XCTAssertEqual(staleReferee.end, .stalemate)
        XCTAssertEqual(staleReferee.submit(rawMove: "h8g8", taunt: ""), .ignored)
    }
}
