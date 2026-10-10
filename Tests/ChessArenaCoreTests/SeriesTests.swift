import XCTest
@testable import ChessArenaCore

final class SeriesTests: XCTestCase {
    func testScoresOnceAndStartsExactlyOneNewGameAfterThirtySeconds() throws {
        var series = MatchSeries()
        let first = series.start()
        XCTAssertTrue(series.complete(round: first, result: .checkmate(winner: .black), now: 100))
        XCTAssertFalse(series.complete(round: first, result: .checkmate(winner: .black), now: 101))
        XCTAssertEqual(series.score.white, "0")
        XCTAssertEqual(series.score.black, "1")
        XCTAssertEqual(series.remaining(at: 100), 30)
        XCTAssertNil(series.nextRoundIfDue(at: 129.99))
        let second = try XCTUnwrap(series.nextRoundIfDue(at: 130))
        XCTAssertNotEqual(first, second)
        XCTAssertNil(series.nextRoundIfDue(at: 131))
        XCTAssertNil(series.result)
        XCTAssertFalse(series.complete(round: first, result: .stalemate, now: 140))
        XCTAssertTrue(series.complete(round: second, result: .stalemate, now: 200))
        XCTAssertEqual(series.score.white, "0½")
        XCTAssertEqual(series.score.black, "1½")
        XCTAssertEqual(series.score.games, 2)
        let saved = try JSONEncoder().encode(series.score)
        XCTAssertEqual(try JSONDecoder().decode(SeriesScore.self, from: saved), series.score)
    }

    func testStopDuringCountdownPreventsRestartAndLateScoring() {
        var series = MatchSeries()
        let round = series.start()
        series.complete(round: round, result: .resignation(loser: .black), now: 0)
        series.stop()
        XCTAssertNil(series.remaining(at: 1))
        XCTAssertNil(series.nextRoundIfDue(at: 300))
        XCTAssertFalse(series.complete(round: round, result: .stalemate, now: 301))
        XCTAssertEqual(series.score.games, 1)
        let next = series.start()
        series.stop()
        XCTAssertFalse(series.complete(round: next, result: .checkmate(winner: .white), now: 302))
    }
}
