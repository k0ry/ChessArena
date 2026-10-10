import AVFoundation
import XCTest
@testable import ChessArenaCore

@MainActor
final class MatchTests: XCTestCase {
    func testBlackAPIFailureShowsPauseBeforeHostRespondsAndRetriesSamePosition() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("JSON") } }
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", "Your turn."))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "White starts.")
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("You are Black") } }
        let fen = rig.engine.referee.position.fen
        rig.chat.fail(where: { $0.system.contains("You are Black") }, error: .http(status: 429, reason: .quota))
        try await waitUntil { rig.engine.paused }
        XCTAssertEqual(rig.engine.picture.pausedPlayer, "ChatGPT")
        XCTAssertNil(rig.engine.picture.thinkingSide)
        XCTAssertTrue(rig.engine.pauseReason?.contains("HTTP 429") == true)
        XCTAssertTrue(rig.engine.pauseReason?.contains("квота") == true)
        XCTAssertFalse(rig.engine.speech.contains { $0.kind == .stall })
        XCTAssertEqual(rig.engine.referee.accepted.count, 1)
        rig.engine.black.apiKey = "replacement-key"
        rig.engine.black.model = "replacement-model"
        rig.engine.resume()
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("You are Black") }.count == 2 }
        let retry = try XCTUnwrap(rig.chat.calls.last { $0.system.contains("You are Black") })
        XCTAssertTrue(retry.user.contains(fen))
        XCTAssertEqual(retry.apiKey, "replacement-key")
        XCTAssertEqual(retry.model, "replacement-model")
        XCTAssertNil(rig.engine.pauseReason)
        XCTAssertNil(rig.engine.picture.pausedPlayer)
        XCTAssertEqual(rig.engine.picture.thinkingSide, .black)
        XCTAssertEqual(rig.engine.referee.position.fen, fen)
    }

    func testCommentaryWaitsUntilTheMoveIsOnTheBoardAndWaitsOnce() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        XCTAssertEqual(rig.engine.picture.thinkingSide, .white)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("JSON") } }
        XCTAssertTrue(rig.engine.speech.filter { $0.kind == .move }.isEmpty)
        await rig.engine.advance(to: 19)
        XCTAssertTrue(rig.engine.speech.filter { $0.kind == .wait }.isEmpty)

        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", "After you."))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        XCTAssertEqual(rig.engine.boardVersion, 1)
        XCTAssertEqual(rig.engine.hostBoardVersions, [1])
        XCTAssertEqual(rig.engine.scene.node(named: "piece-pawn-e4") == nil, false)
        XCTAssertEqual(rig.engine.picture.replies.map(\.side), [.white])
        XCTAssertEqual(rig.engine.picture.replies.map(\.name), ["Grok"])
        XCTAssertTrue(rig.engine.picture.replies[0].text.contains("e2e4"))
        XCTAssertTrue(rig.engine.picture.replies[0].text.contains("After you."))
        XCTAssertNil(rig.engine.picture.thinkingSide)

        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "The pawn has left home and already looks unsure.")
        try await waitUntil { rig.engine.speech.contains { $0.kind == .move } }
        XCTAssertEqual(rig.engine.speech.filter { $0.kind == .move }.map(\.boardVersion), [1])

        let fresh = try makeRig()
        try await fresh.engine.start(at: 0)
        try await waitUntil { fresh.chat.calls.contains { $0.system.contains("JSON") } }
        await fresh.engine.advance(to: 20)
        try await waitUntil { fresh.chat.calls.contains { $0.system.contains("Do not name a move") } }
        fresh.chat.fulfill(where: { $0.system.contains("Do not name a move") }, body: "Still thinking, with great ceremony.")
        try await waitUntil { fresh.engine.speech.contains { $0.kind == .wait } }
        await fresh.engine.advance(to: 45)
        XCTAssertEqual(fresh.engine.speech.filter { $0.kind == .wait }.count, 1)

        let cancelled = try makeRig()
        try await cancelled.engine.start(at: 0)
        try await waitUntil { cancelled.chat.calls.contains { $0.system.contains("JSON") } }
        await cancelled.engine.advance(to: 20)
        try await waitUntil { cancelled.chat.calls.contains { $0.system.contains("Do not name a move") } }
        cancelled.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", "Soon."))
        try await waitUntil { cancelled.engine.boardVersion == 1 }
        cancelled.chat.fulfill(where: { $0.system.contains("Do not name a move") }, body: "Too late to narrate the wait.")
        try await waitUntil { cancelled.chat.calls.contains { $0.system.contains("already on the board") } }
        cancelled.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "There it is.")
        try await waitUntil { cancelled.engine.speech.contains { $0.kind == .move } }
        XCTAssertTrue(cancelled.engine.speech.filter { $0.kind == .wait }.isEmpty)
    }

    func testToneResignationAndStall() async throws {
        let rig = try makeRig()
        let tone = await rig.engine.toneTest()
        XCTAssertEqual(tone.kind, .tone)
        XCTAssertFalse(rig.engine.archive.isOpen)
        XCTAssertEqual(rig.engine.speech.map(\.kind), [.tone])

        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("JSON") } }
        rig.chat.fail(where: { $0.system.contains("JSON") })
        try await waitUntil { rig.chat.calls.contains { $0.user.contains("stalled") } }
        rig.chat.fulfill(where: { $0.user.contains("stalled") }, body: "White has stalled. The match waits.")
        try await waitUntil { rig.engine.speech.contains { $0.kind == .stall } }
        XCTAssertTrue(rig.engine.paused)
        XCTAssertEqual(rig.engine.referee.position.fen, Position.standard().fen)
        let requests = rig.engine.moveRequestCount
        rig.engine.resume()
        try await waitUntil { rig.engine.moveRequestCount == requests + 1 }
        XCTAssertEqual(rig.engine.referee.position.fen, Position.standard().fen)

        let resign = try makeRig()
        try await resign.engine.start(at: 0)
        try await waitUntil { resign.chat.calls.contains { $0.system.contains("JSON") } }
        for _ in 0..<3 {
            try await waitUntil { resign.chat.calls.contains { $0.system.contains("JSON") && resign.engine.referee.end == nil } }
            resign.chat.fulfill(where: { $0.system.contains("JSON") }, body: "not json")
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await waitUntil { resign.chat.calls.contains { $0.user.contains("resigns") } }
        resign.chat.fulfill(where: { $0.user.contains("resigns") }, body: "White resigns, which is a kind of plan.")
        try await waitUntil { resign.engine.speech.contains { $0.kind == .resignation } }
        XCTAssertEqual(resign.engine.referee.end, .resignation(loser: .white))
    }

    func testChronicleFreezesMovesAndSpeaksWhenTheLineArrives() async throws {
        let rig = try makeRig()
        rig.engine.animationDuration = 20
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("JSON") } }
        await rig.engine.advance(to: 290)
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", "Late."))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "A single step, heavily narrated.")
        try await waitUntil { rig.engine.speech.contains { $0.kind == .move } }
        let before = rig.engine.moveRequestCount
        await rig.engine.advance(to: 300)
        XCTAssertEqual(rig.engine.chronicleVisuals, 0)
        await rig.engine.advance(to: 310)
        try await waitUntil { rig.engine.chronicleVisuals == 1 }
        let during = rig.engine.moveRequestCount
        await rig.engine.advance(to: 320)
        XCTAssertEqual(rig.engine.moveRequestCount, during)
        XCTAssertGreaterThanOrEqual(during, before)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("at most 35") } }
        XCTAssertEqual(rig.engine.speech.filter { $0.kind == .chronicle }.count, 0)
        rig.chat.fulfill(where: { $0.system.contains("at most 35") }, body: "One move in five minutes, and White calls it development.")
        try await waitUntil { rig.engine.speech.contains { $0.kind == .chronicle } }
        XCTAssertLessThanOrEqual(rig.engine.speech.first { $0.kind == .chronicle }!.text.split(separator: " ").count, 45)
    }

    func testTwoMoveMatchWritesBoardSpeechPGNAndVideo() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("JSON") } }
        rig.chat.fulfill(where: { $0.user.contains("FEN:") && $0.system.contains("White") }, body: jsonMove("e2e4", "After you."))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "White steps forward and hopes.")
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("Black") } }
        rig.chat.fulfill(where: { $0.system.contains("Black") }, body: jsonMove("e7e5", "Likewise."))
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("already on the board") }.count == 2 }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Black answers in the same accent.")
        try await waitUntil { rig.engine.speech.filter { $0.kind == .move }.count == 2 }
        XCTAssertNotNil(rig.engine.scene.node(named: "piece-pawn-e4"))
        XCTAssertNotNil(rig.engine.scene.node(named: "piece-pawn-e5"))
        rig.engine.appendFrame(FrameBuffer.make(fill: 40))
        try await rig.engine.closeArchive()
        let pgn = try String(contentsOf: rig.engine.archive.pgnURL)
        XCTAssertTrue(pgn.contains("e4"))
        XCTAssertTrue(pgn.contains("e5"))
        XCTAssertTrue(pgn.contains("After you."))
        let journal = try String(contentsOf: rig.engine.archive.journalURL)
        XCTAssertTrue(journal.contains("White steps forward and hopes."))
        XCTAssertTrue(journal.contains("Likewise."))
        let secret = Data("CHESSARENA-SECRET-KEY-9f3c2a7b".utf8)
        let video = try Data(contentsOf: rig.engine.archive.videoURL)
        XCTAssertFalse(video.range(of: secret) != nil && video.count < 0)
        XCTAssertFalse(video.contains(secret))
        XCTAssertFalse(Data(pgn.utf8).contains(secret))
        XCTAssertFalse(Data(journal.utf8).contains(secret))
        let asset = AVURLAsset(url: rig.engine.archive.videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await tracks[0].load(.naturalSize)
        XCTAssertEqual(size.width, 1920, accuracy: 1)
        XCTAssertEqual(size.height, 1080, accuracy: 1)
    }

    private func makeRig() throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = MatchArchive(directory: directory, whiteName: "Grok", blackName: "ChatGPT")
        let chat = ScriptedChat()
        let secret = "CHESSARENA-SECRET-KEY-9f3c2a7b"
        let white = Seat.defaultWhite(apiKey: secret)
        let black = Seat.defaultBlack(apiKey: secret)
        let host = Seat(name: "Host", baseURL: ModelCatalog.grokAPI, model: ModelCatalog.grokModel, apiKey: secret, side: .white)
        let engine = MatchEngine(
            scene: BoardScene(),
            voice: ScriptedVoice(),
            transport: chat,
            archive: archive,
            white: white,
            black: black,
            host: host
        )
        return Rig(engine: engine, chat: chat)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ predicate: @MainActor () -> Bool) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}

private struct Rig {
    var engine: MatchEngine
    var chat: ScriptedChat
}

private func jsonMove(_ uci: String, _ taunt: String) -> String {
    let payload: [String: String] = ["move": uci, "taunt": taunt]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    return String(data: data, encoding: .utf8)!
}
