import XCTest
@testable import ChessArenaCore

final class SessionStoreTests: XCTestCase {
    func testLegacyForfeitIsBackedUpAndRecoveredExactlyOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(url: folder.appendingPathComponent("session.json"))
        var series = MatchSeries()
        let round = series.start()
        let picture = BroadcastPicture(whiteName: "White", blackName: "Black", clockText: "00:00", line: "Old verdict", taunt: "", banner: "BLACK WINS")
        let checkpoint = GameCheckpoint(referee: Referee(), elapsed: 10, picture: picture, requestCount: 3, journal: [])
        let session = SavedSession(game: checkpoint, series: series, white: .init(provider: .deepseek), black: .init(provider: .gemini), hostModel: "host", language: .russian, useChatGPTLogin: false, camera: .init(manual: false, yaw: 0, pitch: 0, distance: 12))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        let oldEnd: [String: Any] = ["resignation": ["loser": "white"]]
        var game = json["game"] as! [String: Any]
        var referee = game["referee"] as! [String: Any]
        referee["end"] = oldEnd; referee["consecutiveFailures"] = 3
        game["referee"] = referee; json["game"] = game
        var oldSeries = json["series"] as! [String: Any]
        oldSeries["result"] = oldEnd; oldSeries["restartAt"] = 50
        oldSeries["score"] = ["games": 2, "whiteHalfPoints": 2, "blackHalfPoints": 2]
        json["series"] = oldSeries
        let original = try JSONSerialization.data(withJSONObject: json)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try original.write(to: store.url)
        for _ in 0..<2 {
            let recovered = try XCTUnwrap(SessionStore(url: store.url).load())
            XCTAssertNil(recovered.game?.referee.end)
            XCTAssertNil(recovered.game?.picture.banner)
            XCTAssertNil(recovered.series.result)
            XCTAssertNil(recovered.series.restartAt)
            XCTAssertFalse(recovered.series.running)
            XCTAssertEqual(recovered.series.roundID, round)
            XCTAssertEqual(recovered.series.score.games, 1)
            XCTAssertEqual(recovered.series.score.whiteHalfPoints, 2)
            XCTAssertEqual(recovered.series.score.blackHalfPoints, 0)
            XCTAssertEqual(recovered.game?.referee.position, .standard())
        }
        XCTAssertEqual(try Data(contentsOf: store.url.appendingPathExtension("before-terminal-only.json")), original)
    }

    func testHostSelectionPersistsAndLegacySessionsKeepTheirGrokModel() throws {
        let state = SavedSession(game: nil, series: MatchSeries(), white: .init(provider: .grok),
                                 black: .init(provider: .grok), hostModel: "selected-commentator-model",
                                 language: .russian, useChatGPTLogin: true,
                                 camera: .init(manual: false, yaw: 0, pitch: 0, distance: 12), hostProvider: .chatGPT)
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(SavedSession.self, from: data)
        XCTAssertEqual(restored.hostConfiguration.provider, .chatGPT)
        XCTAssertEqual(restored.hostConfiguration.model, "selected-commentator-model")

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "hostProvider")
        legacy["hostModel"] = "previous-grok-model"
        let old = try JSONDecoder().decode(SavedSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.hostConfiguration.provider, .grok)
        XCTAssertEqual(old.hostConfiguration.model, "previous-grok-model")
    }

    func testPositionHistoryAndIllegalMoveCounterSurviveRestart() throws {
        var referee = Referee()
        for move in ["e2e4", "a7a6", "e4e5", "d7d5"] { _ = referee.submit(rawMove: move, taunt: "Hi") }
        _ = referee.submit(rawMove: "wrong", taunt: "")
        _ = referee.submit(rawMove: "wrong", taunt: "")
        let data = try JSONEncoder().encode(referee)
        var restored = try JSONDecoder().decode(Referee.self, from: data)
        XCTAssertEqual(referee, restored)
        XCTAssertTrue(restored.legalUCI.contains("e5d6"), "En passant must survive restart")
        XCTAssertEqual(restored.position.castling, referee.position.castling)
        XCTAssertEqual(restored.submit(rawMove: "wrong", taunt: ""), .rejected(reason: "Illegal or unreadable move wrong.", attempt: 3))
    }

    func testResultDeadlineAndExactlyOnceScoreSurviveRestart() throws {
        var series = MatchSeries()
        let round = series.start()
        series.complete(round: round, result: .checkmate(winner: .black), position: terminalBoard(.checkmate(winner: .black)), now: 100)
        var restored = try JSONDecoder().decode(MatchSeries.self, from: JSONEncoder().encode(series))
        XCTAssertEqual(restored.remaining(at: 120), 10)
        XCTAssertFalse(restored.complete(round: round, result: .checkmate(winner: .black), position: terminalBoard(.checkmate(winner: .black)), now: 121))
        XCTAssertEqual(restored.score.games, 1)
        XCTAssertNotNil(restored.nextRoundIfDue(at: 150))
        XCTAssertNil(restored.nextRoundIfDue(at: 151))
        XCTAssertEqual(restored.score.black, "1")
        restored.stop()
        let stopped = try JSONDecoder().decode(MatchSeries.self, from: JSONEncoder().encode(restored))
        XCTAssertFalse(stopped.running)
        XCTAssertNil(stopped.restartAt)
    }

    @MainActor
    func testAtomicSessionUpdatesAndCameraRestoration() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(url: folder.appendingPathComponent("session.json"))
        XCTAssertNil(try store.load())
        let scene = BoardScene()
        scene.orbitCamera(yaw: 0.8, pitch: 0.1)
        scene.zoomCamera(scale: 1.4)
        var state = SavedSession(game: nil, series: MatchSeries(), white: .init(provider: .grok),
                                 black: .init(provider: .chatGPT), hostModel: "host", language: .russian,
                                 useChatGPTLogin: true, camera: scene.cameraCheckpoint)
        try store.save(state)
        state.language = .english
        state.white.model = "selected-player"
        try store.save(state)
        let restored = try XCTUnwrap(SessionStore(url: store.url).load())
        XCTAssertEqual(restored.language, .english)
        XCTAssertEqual(restored.white.model, "selected-player")
        let board = BoardScene()
        board.restoreCamera(restored.camera)
        XCTAssertEqual(board.cameraCheckpoint, scene.cameraCheckpoint)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["session.json"])
    }

    func testCorruptAndFutureFilesAreRejectedWithoutChangingThem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = SessionStore(url: folder.appendingPathComponent("session.json"))
        for text in ["{truncated", "{\"schemaVersion\":999}"] {
            let data = Data(text.utf8)
            try data.write(to: store.url)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try Data(contentsOf: store.url), data)
        }
    }
}
