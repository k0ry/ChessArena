import XCTest
@testable import ChessArenaCore

final class SeriesTests: XCTestCase {
    func testOnlyBoardConfirmedResultsCanChangeScore() {
        var series = MatchSeries()
        let round = series.start()
        for result: GameEnd in [.resignation(loser: .white), .checkmate(winner: .black), .stalemate] {
            XCTAssertFalse(series.complete(round: round, result: result, position: .standard(), now: 0))
            XCTAssertNil(series.result)
            XCTAssertNil(series.restartAt)
            XCTAssertEqual(series.score.games, 0)
        }
        XCTAssertFalse(series.complete(round: round, result: .checkmate(winner: .black), position: terminalBoard(.stalemate), now: 0))
        XCTAssertTrue(series.complete(round: round, result: .stalemate, position: terminalBoard(.stalemate), now: 0))
        XCTAssertFalse(series.complete(round: round, result: .stalemate, position: terminalBoard(.stalemate), now: 1))
        XCTAssertEqual(series.score.games, 1)
        XCTAssertEqual(series.score.whiteHalfPoints, 1)
        XCTAssertEqual(series.score.blackHalfPoints, 1)
    }

    func testContinueAfterRestartKeepsRoundAndScore() throws {
        var series = MatchSeries()
        let finished = series.start()
        series.complete(round: finished, result: .checkmate(winner: .white), position: terminalBoard(.checkmate(winner: .white)), now: 0)
        let unfinished = series.start()
        var restored = try JSONDecoder().decode(MatchSeries.self, from: JSONEncoder().encode(series))
        restored.stop()
        XCTAssertFalse(restored.running)
        XCTAssertNil(restored.nextRoundIfDue(at: 1_000))
        XCTAssertEqual(restored.resumeRound(), unfinished)
        XCTAssertTrue(restored.running)
        XCTAssertEqual(restored.score, series.score)
        XCTAssertFalse(restored.complete(round: finished, result: .stalemate, position: terminalBoard(.stalemate), now: 1_001))
        XCTAssertTrue(restored.complete(round: unfinished, result: .stalemate, position: terminalBoard(.stalemate), now: 1_002))
        XCTAssertEqual(restored.score.games, 2)
        XCTAssertEqual(restored.score.white, "1½")
    }

    func testNewGameKeepsScoreAndDiscardsUnfinishedRound() {
        var series = MatchSeries()
        let finished = series.start()
        series.complete(round: finished, result: .checkmate(winner: .black), position: terminalBoard(.checkmate(winner: .black)), now: 0)
        let abandoned = series.start()
        let next = series.start()
        XCTAssertNotEqual(next, abandoned)
        XCTAssertNil(series.result)
        XCTAssertNil(series.restartAt)
        XCTAssertEqual(series.score.games, 1)
        XCTAssertEqual(series.score.black, "1")
        XCTAssertFalse(series.complete(round: abandoned, result: .checkmate(winner: .white), position: terminalBoard(.checkmate(winner: .white)), now: 10))
        XCTAssertEqual(series.score.games, 1)
    }

    func testNewSeriesResetsScoreAndRejectsOldRoundResults() throws {
        var series = MatchSeries()
        let old = series.start()
        series.complete(round: old, result: .checkmate(winner: .black), position: terminalBoard(.checkmate(winner: .black)), now: 0)
        let new = series.startNewSeries()
        XCTAssertNotEqual(old, new)
        XCTAssertTrue(series.running)
        XCTAssertEqual(series.score, SeriesScore())
        XCTAssertNil(series.result)
        XCTAssertNil(series.restartAt)
        XCTAssertFalse(series.complete(round: old, result: .stalemate, position: terminalBoard(.stalemate), now: 10))
        let restored = try JSONDecoder().decode(MatchSeries.self, from: JSONEncoder().encode(series))
        XCTAssertEqual(restored.score, SeriesScore())
        XCTAssertEqual(restored.roundID, new)
    }

    func testFinishedGameCannotContinueAfterRestart() throws {
        var series = MatchSeries()
        let round = series.start()
        series.complete(round: round, result: .stalemate, position: terminalBoard(.stalemate), now: 0)
        var restored = try JSONDecoder().decode(MatchSeries.self, from: JSONEncoder().encode(series))
        restored.stop()
        XCTAssertNil(restored.resumeRound())
        XCTAssertFalse(restored.running)
        XCTAssertNil(restored.nextRoundIfDue(at: 1_000))
        XCTAssertEqual(restored.score.games, 1)
    }

    func testScoreIsRecordedBeforeSummaryButCountdownWaitsForIt() {
        var series = MatchSeries()
        let round = series.start()
        XCTAssertTrue(series.complete(round: round, result: .checkmate(winner: .white), position: terminalBoard(.checkmate(winner: .white)), now: 0, startIntermission: false))
        XCTAssertEqual(series.score.white, "1")
        XCTAssertNil(series.remaining(at: 100))
        XCTAssertNil(series.nextRoundIfDue(at: 100))
        XCTAssertTrue(series.beginIntermission(round: round, now: 100))
        XCTAssertFalse(series.beginIntermission(round: round, now: 110))
        XCTAssertEqual(series.remaining(at: 110), 20)
        XCTAssertNil(series.nextRoundIfDue(at: 129))
        XCTAssertNotNil(series.nextRoundIfDue(at: 130))
        XCTAssertEqual(series.score.games, 1)
        series.stop()
        XCTAssertFalse(series.beginIntermission(round: round, now: 200))
    }

    func testScoresOnceAndStartsExactlyOneNewGameAfterThirtySeconds() throws {
        var series = MatchSeries()
        let first = series.start()
        XCTAssertTrue(series.complete(round: first, result: .checkmate(winner: .black), position: terminalBoard(.checkmate(winner: .black)), now: 100))
        XCTAssertFalse(series.complete(round: first, result: .checkmate(winner: .black), position: terminalBoard(.checkmate(winner: .black)), now: 101))
        XCTAssertEqual(series.score.white, "0")
        XCTAssertEqual(series.score.black, "1")
        XCTAssertEqual(series.remaining(at: 100), 30)
        XCTAssertNil(series.nextRoundIfDue(at: 129.99))
        let second = try XCTUnwrap(series.nextRoundIfDue(at: 130))
        XCTAssertNotEqual(first, second)
        XCTAssertNil(series.nextRoundIfDue(at: 131))
        XCTAssertNil(series.result)
        XCTAssertFalse(series.complete(round: first, result: .stalemate, position: terminalBoard(.stalemate), now: 140))
        XCTAssertTrue(series.complete(round: second, result: .stalemate, position: terminalBoard(.stalemate), now: 200))
        XCTAssertEqual(series.score.white, "0½")
        XCTAssertEqual(series.score.black, "1½")
        XCTAssertEqual(series.score.games, 2)
        let saved = try JSONEncoder().encode(series.score)
        XCTAssertEqual(try JSONDecoder().decode(SeriesScore.self, from: saved), series.score)
    }

    func testStopDuringCountdownPreventsRestartAndLateScoring() {
        var series = MatchSeries()
        let round = series.start()
        series.complete(round: round, result: .checkmate(winner: .white), position: terminalBoard(.checkmate(winner: .white)), now: 0)
        series.stop()
        XCTAssertNil(series.remaining(at: 1))
        XCTAssertNil(series.nextRoundIfDue(at: 300))
        XCTAssertFalse(series.complete(round: round, result: .stalemate, position: terminalBoard(.stalemate), now: 301))
        XCTAssertEqual(series.score.games, 1)
        let next = series.start()
        series.stop()
        XCTAssertFalse(series.complete(round: next, result: .checkmate(winner: .white), position: terminalBoard(.checkmate(winner: .white)), now: 302))
    }
}
