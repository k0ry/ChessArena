import XCTest
@testable import ChessArenaCore

final class BanterTests: XCTestCase {
    func testTwentyOfOneHundredDrawsPermitOrdinaryTaunts() {
        XCTAssertEqual((0..<100).filter(BanterPolicy.randomlyAllowed).count, 20)
        XCTAssertTrue(BanterPolicy.randomlyAllowed(draw: 19))
        XCTAssertFalse(BanterPolicy.randomlyAllowed(draw: 20))
        XCTAssertFalse(BanterPolicy.randomlyAllowed(draw: 99))
    }

    func testImportantEventsAndOrdinaryMoves() throws {
        func important(_ fen: String, _ uci: String) throws -> Bool {
            let position = try XCTUnwrap(Position.position(fen: fen))
            let move = try XCTUnwrap(position.parseUCI(uci))
            XCTAssertTrue(position.isLegal(move))
            return BanterPolicy.isImportant(move, in: position)
        }
        XCTAssertFalse(try important(Position.standard().fen, "e2e4"))
        XCTAssertFalse(try important("4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1", "e4d5"))
        XCTAssertFalse(try important("4k3/8/8/8/8/8/8/4K2R w K - 0 1", "e1g1"))
        XCTAssertTrue(try important("4k3/P7/8/8/8/8/8/4K3 w - - 0 1", "a7a8q"))
        XCTAssertTrue(try important("4k3/8/8/3q4/4P3/8/8/4K3 w - - 0 1", "e4d5"))
        XCTAssertTrue(try important("4k3/8/8/3r4/4P3/8/8/4K3 w - - 0 1", "e4d5"))
        XCTAssertTrue(try important("4k3/8/8/8/8/8/8/R3K3 w - - 0 1", "a1a8"))
    }

    func testRepeatDetectionNormalizesPunctuationAndOpeningWords() {
        XCTAssertTrue(BanterPolicy.repeats("Ну что, пешка опять?", recent: ["Ну что — пешка ушла."]))
        XCTAssertTrue(BanterPolicy.repeats("Fine!", recent: ["fine."]))
        XCTAssertFalse(BanterPolicy.repeats("Король ищет выход.", recent: ["Пешка нашла работу."]))
        XCTAssertEqual(Set((0..<8).map(BanterPolicy.delivery)).count, 8)
        for language in [BroadcastLanguage.russian, .english] {
            for event in [CommentaryStyle.Event.move, .waiting] {
                let lines = (0..<8).map { CommentaryStyle.zadornov.fallback(for: event, language: language, variation: $0) }
                XCTAssertEqual(Set(lines).count, 8)
            }
        }
    }

    func testPromptsCarryHistoryAndSilencePermissionWithoutCelebrityNames() {
        let prompt = Prompts.player(side: .white, fen: Position.standard().fen, legal: ["e2e4"],
                                    history: [], rejection: nil, persona: .burr,
                                    recentRemarks: ["An old joke."], variation: 3)
        XCTAssertTrue(prompt.user.contains("An ordinary move requires silence"))
        XCTAssertTrue(prompt.user.contains("An old joke."))
        XCTAssertTrue(prompt.user.contains("playful question"))
        XCTAssertFalse(CommentaryStyle.zadornov.instruction.contains("Zadornov"))
        XCTAssertEqual(PlayerPersona.burr.displayName(.russian), "Спорщик")
    }
}
