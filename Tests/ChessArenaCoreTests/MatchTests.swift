import AVFoundation
import XCTest
@testable import ChessArenaCore

@MainActor
final class MatchTests: XCTestCase {
    func testEscapedCommentaryIsCleanedForScreenSpeechAndJournal() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        rig.chat.fulfill(where: { $0.system.contains("Reply with JSON") }, body: jsonMove("e2e4", ""))
        try await waitUntil { rig.chat.calls.count == 2 }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: #"Ход сделан.\nbackslash ＼ План \"надёжный\"."#)
        try await waitUntil { rig.engine.moveRequestCount == 2 }
        let expected = "Ход сделан. План \"надёжный\"."
        XCTAssertEqual(rig.engine.picture.line, expected)
        XCTAssertEqual(rig.engine.speech.last?.text, expected)
        XCTAssertEqual(rig.engine.archive.journal.last?.text, expected)
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testCompletedGameAdvicePersistsAndReachesOnlyItsPlayerInNextGame() async throws {
        let config = PlayerConfiguration(provider: .grok)
        let rig = try makeRig(whitePlayer: config, blackPlayer: config)
        var saved = rig.engine.checkpoint
        var memory = GameMemory()
        memory.remember("OLD_WHITE_LESSON", for: rig.engine.white)
        memory.remember("OLD_BLACK_LESSON", for: rig.engine.black)
        saved.gameMemory = memory
        saved.whiteSelfNotes = "WHITE_TURN_NOTE"
        saved.blackSelfNotes = "BLACK_TURN_NOTE"
        for move in ["f2f3", "e7e5", "g2g4"] { _ = saved.referee.submit(rawMove: move, taunt: "") }
        rig.engine.restore(saved)
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        XCTAssertEqual(rig.engine.picture.thinkingSelfNotes, "BLACK_TURN_NOTE")
        XCTAssertFalse(rig.engine.picture.broadcastText.contains("OLD_BLACK_LESSON"))
        rig.chat.fulfill(where: { $0.system.contains("Reply with JSON") }, body: jsonMove("d8h4", ""))
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("Post-game self-review") }.count == 2 }
        let reviews = rig.chat.calls.filter { $0.system.contains("Post-game self-review") }
        for call in reviews {
            let white = call.user.contains("You played: White")
            XCTAssertEqual(call.gameAdvice, white ? "OLD_WHITE_LESSON" : "OLD_BLACK_LESSON")
            XCTAssertEqual(call.selfNotes, white ? "WHITE_TURN_NOTE" : "BLACK_TURN_NOTE")
            XCTAssertTrue(call.user.contains("Qh4#"))
            XCTAssertTrue(call.user.contains("CHECKMATE · BLACK"))
            XCTAssertTrue(call.user.contains("Final FEN:"))
            XCTAssertFalse(call.inputMessages.contains { $0["content"]?.contains(white ? "BLACK_LESSON" : "WHITE_LESSON") == true })
        }
        rig.chat.fulfill(where: { $0.user.contains("Result:") }, body: "Black wins.")
        try await waitUntil { rig.engine.phase == "learning" }
        await rig.engine.advance(to: 60)
        XCTAssertEqual(rig.engine.finalCards, 0, "Countdown waits for the players' plans")
        rig.chat.fulfill(where: { $0.user.contains("You played: White") }, body: "WHITE_NEXT_PLAN")
        try await waitUntil { rig.engine.gameMemory.advice(for: rig.engine.white) == "WHITE_NEXT_PLAN" }
        XCTAssertEqual(rig.engine.checkpoint.gameMemory?.advice(for: rig.engine.white), "WHITE_NEXT_PLAN", "Save each side immediately")
        rig.chat.fulfill(where: { $0.user.contains("You played: Black") }, body: "BLACK_NEXT_PLAN")
        try await waitUntil { rig.engine.finalCards == 1 }
        let roundTrip = try JSONDecoder().decode(GameCheckpoint.self, from: JSONEncoder().encode(rig.engine.checkpoint))
        rig.engine.stop()
        try await rig.engine.closeArchive()

        let next = try makeRig(whitePlayer: config, blackPlayer: config, gameMemory: try XCTUnwrap(roundTrip.gameMemory))
        try await next.engine.start(at: 0)
        try await waitUntil { next.chat.calls.count == 1 }
        XCTAssertEqual(next.chat.calls[0].gameAdvice, "WHITE_NEXT_PLAN")
        XCTAssertNil(next.chat.calls[0].selfNotes, "Turn notes must not carry an old position into a new game")
        XCTAssertNil(next.engine.picture.thinkingSelfNotes, "Previous games' advice must not appear on the broadcast")
        XCTAssertFalse(next.engine.picture.broadcastText.contains("WHITE_NEXT_PLAN"))
        next.chat.fulfill(where: { $0.system.contains("Reply with JSON") }, body: jsonMove("e2e4", ""))
        try await waitUntil { next.chat.calls.count == 2 }
        XCTAssertNil(next.chat.calls[1].gameAdvice, "The host must not receive private plans")
        next.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Played.")
        try await waitUntil { next.chat.calls.count == 3 }
        XCTAssertEqual(next.chat.calls[2].gameAdvice, "BLACK_NEXT_PLAN")
        XCTAssertNil(next.chat.calls[2].selfNotes)
        XCTAssertNil(next.engine.picture.thinkingSelfNotes)
        next.engine.stop()
        try await next.engine.closeArchive()
    }

    func testFailedOrLateAdviceKeepsPreviousMemoryAndDoesNotBlockSeries() async throws {
        let rig = try makeRig()
        var saved = rig.engine.checkpoint
        var memory = GameMemory()
        memory.remember("PREVIOUS_PLAN", for: rig.engine.white)
        saved.gameMemory = memory
        for move in ["f2f3", "e7e5", "g2g4"] { _ = saved.referee.submit(rawMove: move, taunt: "") }
        rig.engine.restore(saved)
        rig.engine.learningTimeout = 0.08
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        rig.chat.fulfill(where: { $0.system.contains("Reply with JSON") }, body: jsonMove("d8h4", ""))
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("Post-game self-review") }.count == 2 }
        rig.chat.fail(where: { $0.user.contains("You played: White") })
        rig.chat.fulfill(where: { $0.user.contains("Result:") }, body: "Black wins.")
        try await waitUntil { rig.engine.finalCards == 1 }
        XCTAssertEqual(rig.engine.gameMemory.advice(for: rig.engine.white), "PREVIOUS_PLAN")
        XCTAssertNil(rig.engine.gameMemory.advice(for: rig.engine.black))
        rig.chat.fulfill(where: { $0.user.contains("You played: Black") }, body: "TOO_LATE")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(rig.engine.gameMemory.advice(for: rig.engine.black))
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testStoppingDuringAdviceDiscardsLatePlans() async throws {
        let rig = try makeRig()
        var saved = rig.engine.checkpoint
        for move in ["f2f3", "e7e5", "g2g4"] { _ = saved.referee.submit(rawMove: move, taunt: "") }
        rig.engine.restore(saved)
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        rig.chat.fulfill(where: { $0.system.contains("Reply with JSON") }, body: jsonMove("d8h4", ""))
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("Post-game self-review") }.count == 2 }
        rig.engine.stop()
        rig.chat.fulfill(where: { $0.user.contains("You played: White") }, body: "LATE_WHITE")
        rig.chat.fulfill(where: { $0.user.contains("You played: Black") }, body: "LATE_BLACK")
        rig.chat.fulfill(where: { $0.user.contains("Result:") }, body: "Late verdict.")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(rig.engine.gameMemory.advice(for: rig.engine.white))
        XCTAssertNil(rig.engine.gameMemory.advice(for: rig.engine.black))
        XCTAssertEqual(rig.engine.finalCards, 0)
        try await rig.engine.closeArchive()
    }

    func testSelectedCommentatorUsesItsOwnProviderModelAndKeyWithoutPlayerNotes() async throws {
        for provider in [NeuralProvider.grok, .chatGPT] {
            var host = PlayerConfiguration(provider: provider)
            host.model = "selected-commentator-model"
            let rig = try makeRig(hostPlayer: host)
            try await rig.engine.start(at: 0)
            try await waitUntil { rig.chat.calls.count == 1 }
            rig.chat.fulfill(where: { $0.system.contains("Reply with JSON") },
                             body: #"{"move":"e2e4","taunt":"Go.","self_notes":"PRIVATE_PLAYER_PLAN"}"#)
            try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
            let call = try XCTUnwrap(rig.chat.calls.last)
            XCTAssertEqual(call.url, provider.baseURL.appendingPathComponent("chat/completions"))
            XCTAssertEqual(call.model, "selected-commentator-model")
            XCTAssertEqual(call.apiKey, provider == .grok ? "grok-key" : "openai-key")
            XCTAssertNil(call.selfNotes)
            XCTAssertFalse(call.user.contains("PRIVATE_PLAYER_PLAN"))
            rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Комментарий выбранной модели.")
            try await waitUntil { rig.engine.moveRequestCount == 2 }
            XCTAssertEqual(rig.engine.speech.last?.text, "Комментарий выбранной модели.")
            rig.engine.stop()
            try await rig.engine.closeArchive()
        }
    }

    func testSelfNotesStayWithTheirPlayerAndSurviveRestore() async throws {
        // Even two seats using the same provider and model must not share notes.
        let config = PlayerConfiguration(provider: .grok)
        let rig = try makeRig(whitePlayer: config, blackPlayer: config)
        try await rig.engine.start(at: 0)
        let moves = ["e2e4", "e7e5", "g1f3", "b8c6"]
        let notes = ["WHITE_PRIVATE_PLAN", "BLACK_PRIVATE_PLAN", "WHITE_UPDATED_PLAN", ""]
        for index in moves.indices {
            try await waitUntil { rig.chat.calls.filter { $0.system.contains("Reply with JSON") }.count == index + 1 }
            let call = try XCTUnwrap(rig.chat.calls.last)
            XCTAssertEqual(call.selfNotes, index < 2 ? nil : notes[index - 2])
            XCTAssertEqual(rig.engine.picture.thinkingSide, index.isMultiple(of: 2) ? .white : .black)
            XCTAssertEqual(rig.engine.picture.thinkingSelfNotes, call.selfNotes)
            XCTAssertFalse(call.inputMessages.contains { $0["content"]?.contains(index.isMultiple(of: 2) ? "BLACK_PRIVATE_PLAN" : "WHITE_PRIVATE_PLAN") == true })
            let body = try JSONSerialization.data(withJSONObject: ["move": moves[index], "taunt": "Go.", "self_notes": notes[index]])
            rig.chat.fulfill(where: { $0.system.contains("Reply with JSON") }, body: String(decoding: body, as: UTF8.self))
            try await waitUntil { rig.chat.calls.filter { $0.system.contains("already on the board") }.count == index + 1 }
            XCTAssertNil(rig.chat.calls.last?.selfNotes)
            XCTAssertNil(rig.engine.picture.thinkingSide)
            XCTAssertNil(rig.engine.picture.thinkingSelfNotes)
            XCTAssertFalse(rig.chat.calls.last!.user.contains("PRIVATE_PLAN"))
            rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Played.")
        }
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("Reply with JSON") }.count == 5 }
        XCTAssertEqual(rig.chat.calls.last?.selfNotes, "WHITE_UPDATED_PLAN")
        let encoded = try JSONEncoder().encode(rig.engine.checkpoint)
        let saved = try JSONDecoder().decode(GameCheckpoint.self, from: encoded)
        XCTAssertEqual(saved.whiteSelfNotes, "WHITE_UPDATED_PLAN")
        XCTAssertEqual(saved.blackSelfNotes, "")
        rig.engine.stop()
        try await rig.engine.closeArchive()

        let restored = try makeRig()
        restored.engine.restore(saved)
        try await restored.engine.start(at: 0)
        try await waitUntil { restored.chat.calls.count == 1 }
        XCTAssertEqual(restored.chat.calls[0].selfNotes, "WHITE_UPDATED_PLAN")
        // A rejected move cannot overwrite the last accepted plan.
        restored.chat.fulfill(where: { $0.system.contains("Reply with JSON") }, body: #"{"move":"a1a8","self_notes":"BAD_PLAN"}"#)
        try await waitUntil { restored.chat.calls.count == 2 }
        XCTAssertEqual(restored.chat.calls[1].selfNotes, "WHITE_UPDATED_PLAN")
        XCTAssertEqual(restored.engine.picture.thinkingSelfNotes, "WHITE_UPDATED_PLAN")

        restored.chat.fulfill(where: { $0.system.contains("Reply with JSON") }, body: jsonMove("f1c4", "Go."))
        try await waitUntil { restored.engine.boardVersion == 5 }
        XCTAssertEqual(restored.engine.checkpoint.whiteSelfNotes, "WHITE_UPDATED_PLAN")
        restored.engine.stop()
        try await restored.engine.closeArchive()

        // Existing saved sessions decode without the new optional fields.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "whiteSelfNotes")
        legacy.removeValue(forKey: "blackSelfNotes")
        var legacyPicture = try XCTUnwrap(legacy["picture"] as? [String: Any])
        legacyPicture.removeValue(forKey: "thinkingSelfNotes")
        legacy["picture"] = legacyPicture
        let old = try JSONDecoder().decode(GameCheckpoint.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.picture.thinkingSelfNotes)
        XCTAssertNil(old.whiteSelfNotes)
        XCTAssertNil(old.blackSelfNotes)
        let fresh = try makeRig()
        XCTAssertNil(fresh.engine.checkpoint.whiteSelfNotes)
        XCTAssertNil(fresh.engine.checkpoint.blackSelfNotes)
    }

    func testEveryProviderPairRoutesMovesAndKeepsHostOnGrok() async throws {
        for whiteProvider in NeuralProvider.allCases {
            for blackProvider in NeuralProvider.allCases {
                var white = PlayerConfiguration(provider: whiteProvider)
                var black = PlayerConfiguration(provider: blackProvider)
                white.model = "white-selected-model"
                black.model = "black-selected-model"
                let rig = try makeRig(whitePlayer: white, blackPlayer: black)
                try await rig.engine.start(at: 0)
                try await waitUntil { rig.chat.calls.contains { $0.system.contains("You are White") } }
                let opening = try XCTUnwrap(rig.chat.calls.first { $0.system.contains("You are White") })
                XCTAssertEqual(opening.url.host, whiteProvider.baseURL.host)
                XCTAssertEqual(opening.apiKey, whiteProvider == .gemini ? "" : whiteProvider == .grok ? "grok-key" : "openai-key")
                XCTAssertEqual(opening.model, "white-selected-model")
                XCTAssertEqual(opening.route, whiteProvider == .gemini ? .geminiCLI : .http)
                rig.chat.fulfill(where: { $0.system.contains("You are White") }, body: jsonMove("e2e4", "Go."))
                try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
                let host = try XCTUnwrap(rig.chat.calls.first { $0.system.contains("already on the board") })
                XCTAssertEqual(host.url.host, "api.x.ai")
                XCTAssertEqual(host.model, ModelCatalog.grokModel)
                rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "White starts.")
                try await waitUntil { rig.chat.calls.contains { $0.system.contains("You are Black") } }
                let reply = try XCTUnwrap(rig.chat.calls.first { $0.system.contains("You are Black") })
                XCTAssertEqual(reply.url.host, blackProvider.baseURL.host)
                XCTAssertEqual(reply.apiKey, blackProvider == .gemini ? "" : blackProvider == .grok ? "grok-key" : "openai-key")
                XCTAssertEqual(reply.model, "black-selected-model")
                XCTAssertEqual(reply.route, blackProvider == .gemini ? .geminiCLI : .http)
                XCTAssertEqual(rig.engine.picture.whiteName, whiteProvider.rawValue)
                XCTAssertEqual(rig.engine.picture.blackName, blackProvider.rawValue)
                XCTAssertEqual(rig.engine.picture.replies.first?.name, whiteProvider.rawValue)
                rig.chat.fail(where: { $0.system.contains("You are Black") })
                try await waitUntil { rig.engine.paused }
                rig.engine.stop()
                try await rig.engine.closeArchive()
            }
        }
    }

    func testCLIErrorPausesWithoutIllegalMoveOrAutomaticRetry() async throws {
        let rig = try makeRig(whitePlayer: PlayerConfiguration(provider: .gemini))
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        let original = rig.engine.referee.position.fen
        rig.chat.fail(where: { $0.route == .geminiCLI }, error: .cli(.invalidResponse))
        try await waitUntil { rig.engine.paused }
        XCTAssertNil(rig.engine.retryAt)
        var referee = rig.engine.referee
        if case .rejected(_, let attempt) = referee.submit(rawMove: "invalid", taunt: "") {
            XCTAssertEqual(attempt, 1)
        } else { XCTFail("CLI failure must not count as an illegal move") }
        await rig.engine.advance(to: 1000)
        XCTAssertEqual(rig.engine.moveRequestCount, 1)
        XCTAssertEqual(rig.engine.referee.position.fen, original)
        rig.engine.white.model = "gemini-corrected-model"
        rig.engine.resume()
        try await waitUntil { rig.chat.calls.count == 2 }
        XCTAssertEqual(rig.chat.calls.last?.model, "gemini-corrected-model")
        XCTAssertTrue(rig.chat.calls.last?.user.contains(original) == true)
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testBlackAPIFailureRetriesAutomaticallyWithSamePosition() async throws {
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
        await rig.engine.advance(to: 2)
        XCTAssertEqual(rig.engine.moveRequestCount, 2)
        await rig.engine.advance(to: 3)
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
        try await waitUntil { rig.engine.paused }
        XCTAssertEqual(rig.engine.retryAt, 3)
        XCTAssertTrue(rig.engine.paused)
        XCTAssertEqual(rig.engine.referee.position.fen, Position.standard().fen)
        let requests = rig.engine.moveRequestCount
        await rig.engine.advance(to: 3)
        try await waitUntil { rig.engine.moveRequestCount == requests + 1 }
        rig.engine.stop()
        XCTAssertEqual(rig.engine.referee.position.fen, Position.standard().fen)

        let resign = try makeRig()
        resign.engine.learningTimeout = 0.03
        try await resign.engine.start(at: 0)
        try await waitUntil { resign.chat.calls.contains { $0.system.contains("JSON") } }
        for _ in 0..<3 {
            try await waitUntil { resign.chat.calls.contains { $0.system.contains("JSON") && resign.engine.referee.end == nil } }
            resign.chat.fulfill(where: { $0.system.contains("JSON") }, body: "not json")
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await waitUntil { resign.chat.calls.contains { $0.user.contains("Result:") } }
        resign.chat.fulfill(where: { $0.user.contains("Result:") }, body: "ChatGPT wins.")
        try await waitUntil { resign.engine.finalCards == 1 }
        XCTAssertEqual(resign.engine.picture.banner, "ChatGPT WINS")
        XCTAssertEqual(resign.engine.referee.end, .resignation(loser: .white))
    }

    func testMovesContinueAcrossFiveMinuteMarksWithoutRecaps() async throws {
        let rig = try makeRig()
        rig.engine.animationDuration = 1.2
        try await rig.engine.start(at: 0)
        let moves = ["e2e4", "e7e5", "g1f3"]
        for (index, move) in moves.enumerated() {
            let mark = Double(index + 1) * 300
            try await waitUntil { rig.chat.calls.filter { $0.system.contains("JSON") }.count == index + 1 }
            await rig.engine.advance(to: mark - 40)
            await rig.engine.advance(to: mark)
            rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove(move, "Go."))
            try await waitUntil { rig.engine.referee.accepted.count == index + 1 }
            try await waitUntil { rig.chat.calls.filter { $0.system.contains("already on the board") }.count == index + 1 }
            rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "The game continues.")
            try await waitUntil { rig.engine.moveRequestCount == index + 2 }
            await rig.engine.advance(to: mark + 2)
            XCTAssertEqual(rig.engine.director.phase, .live)
            XCTAssertEqual(rig.engine.picture.thinkingSide, rig.engine.referee.position.sideToMove)
            XCTAssertNil(rig.engine.picture.banner)
            XCTAssertFalse(rig.engine.paused)
        }
        XCTAssertFalse(rig.chat.calls.contains { $0.system.contains("Summarize the whole game from move one") })
        XCTAssertFalse(rig.engine.speech.contains { $0.kind == .chronicle })
        XCTAssertNotNil(rig.engine.scene.node(named: "piece-knight-f3"))
        try await rig.engine.closeArchive()
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

    func testManualRepeatSendsIdenticalRequestAndIgnoresCancelledReply() async throws {
        let rig = try makeRig()
        let log = ModelLog()
        rig.engine.modelLog = log
        XCTAssertFalse(rig.engine.canRepeatPlayerRequest)
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        let original = rig.chat.calls[0]
        let originalID = try XCTUnwrap(log.entries.first?.id)
        XCTAssertTrue(rig.engine.canRepeatPlayerRequest)
        rig.engine.repeatPlayerRequest()
        try await waitUntil { rig.chat.calls.count == 2 }
        XCTAssertEqual(rig.chat.calls[1], original)
        try await waitUntil { log.entries.first { $0.id == originalID }?.status == .cancelled }
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("d2d4", "late"))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(rig.engine.boardVersion, 0)
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", "current"))
        try await waitUntil { rig.engine.boardVersion == 1 }
        XCTAssertFalse(rig.engine.canRepeatPlayerRequest)
        let count = rig.engine.moveRequestCount
        rig.engine.repeatPlayerRequest()
        XCTAssertEqual(rig.engine.moveRequestCount, count)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "White played.")
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("You are Black") } }
        let black = try XCTUnwrap(rig.chat.calls.last { $0.system.contains("You are Black") })
        rig.engine.repeatPlayerRequest()
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("You are Black") }.count == 2 }
        XCTAssertEqual(rig.chat.calls.last { $0.system.contains("You are Black") }, black)
        XCTAssertEqual(rig.engine.referee.accepted.count, 1)
        rig.engine.stop()
        XCTAssertFalse(rig.engine.canRepeatPlayerRequest)
        try await rig.engine.closeArchive()
    }

    func testManualRepeatDuringRetryBackoffSendsImmediatelyAndClearsTimer() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        let original = rig.chat.calls[0]
        rig.chat.fail(where: { $0.system.contains("JSON") }, error: .timeout)
        try await waitUntil { rig.engine.paused }
        XCTAssertTrue(rig.engine.canRepeatPlayerRequest)
        XCTAssertNotNil(rig.engine.retryAt)
        rig.engine.repeatPlayerRequest()
        try await waitUntil { rig.chat.calls.count == 2 }
        XCTAssertFalse(rig.engine.paused)
        XCTAssertNil(rig.engine.retryAt)
        XCTAssertEqual(rig.chat.calls[1], original)
        await rig.engine.advance(to: 3)
        XCTAssertEqual(rig.engine.moveRequestCount, 2)
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testHungRequestTimesOutAndLateReplyCannotMakeAMove() async throws {
        let rig = try makeRig()
        rig.engine.requestTimeout = 0.03
        let log = ModelLog()
        rig.engine.modelLog = log
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.engine.paused }
        XCTAssertEqual(rig.engine.retryAt, 3)
        XCTAssertEqual(log.entries.first?.status, .failed)
        XCTAssertEqual(log.entries.first?.error, ChatError.timeout.userMessage)
        let failedID = log.entries.first?.id
        rig.engine.requestTimeout = RequestTimeouts.player
        await rig.engine.advance(to: 3)
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("JSON") }.count == 2 }
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("d2d4", "stale"))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(rig.engine.boardVersion, 0)
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", "current"))
        try await waitUntil { rig.engine.boardVersion == 1 }
        XCTAssertEqual(rig.engine.referee.accepted.first?.move.uci, "e2e4")
        XCTAssertTrue(log.entries.contains { $0.response?.contains("e2e4") == true && $0.status == .received })
        XCTAssertEqual(log.entries.first { $0.id == failedID }?.status, .failed)
        XCTAssertFalse(log.entries.contains { $0.response?.contains("stale") == true })
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testCommentatorStylesRotateAndContinueFromSavedHistory() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        for (index, move) in ["e2e4", "e7e5", "g1f3", "b8c6"].enumerated() {
            try await waitUntil { rig.chat.calls.filter { $0.system.contains("Reply with JSON") }.count == index + 1 }
            rig.chat.fulfill(where: { $0.system.contains("Reply with JSON") }, body: jsonMove(move, ""))
            try await waitUntil { rig.chat.calls.filter { $0.system.contains("already on the board") }.count == index + 1 }
            let host = try XCTUnwrap(rig.chat.calls.last)
            let expected = ["HOUSE", "CARLIN", "ZADORNOV", "HOUSE"][index]
            XCTAssertTrue(host.system.contains("Commentary style: " + expected + "."))
            if index > 0 { XCTAssertTrue(host.user.contains("Comment number \(index - 1)")) }
            rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Comment number \(index)")
            try await waitUntil { rig.engine.speech.filter { $0.kind == .move }.count == index + 1 }
        }
        let checkpoint = rig.engine.checkpoint
        rig.engine.stop()
        try await rig.engine.closeArchive()
        let restored = try makeRig()
        restored.engine.restore(checkpoint)
        try await restored.engine.start(at: 0)
        await restored.engine.advance(to: 20)
        try await waitUntil { restored.chat.calls.contains { $0.system.contains("Do not name a move") } }
        let waiting = try XCTUnwrap(restored.chat.calls.first { $0.system.contains("Do not name a move") })
        XCTAssertTrue(waiting.system.contains("Commentary style: CARLIN."))
        restored.chat.fail(where: { $0.system.contains("Do not name a move") }, error: .transport)
        try await waitUntil { restored.engine.speech.contains { $0.kind == .wait } }
        XCTAssertEqual(restored.engine.speech.last?.text, "Call indecision strategy and suddenly it looks expensive.")
        restored.engine.stop()
        try await restored.engine.closeArchive()
    }

    func testHostTimeoutUsesSelectedLanguageAndGameContinues() async throws {
        for language in BroadcastLanguage.allCases {
            let rig = try makeRig()
            rig.engine.language = language
            rig.engine.hostTimeout = 0.03
            try await rig.engine.start(at: 0)
            try await waitUntil { rig.chat.calls.contains { $0.system.contains("JSON") } }
            XCTAssertTrue(rig.chat.calls[0].system.contains(language == .russian ? "Russian" : "English"))
            rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", ""))
            try await waitUntil { rig.engine.moveRequestCount == 2 }
            XCTAssertEqual(rig.engine.speech.last?.text, language == .russian ? "Ход сделан. План выглядит уверенно — симптомы пока собираем." : "A move, confidently delivered. We are still collecting symptoms.")
            XCTAssertEqual(rig.engine.voice.language, language)
            rig.engine.stop()
            try await rig.engine.closeArchive()
        }
    }

    func testStopCancelsPendingMoveAndAutomaticRetry() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("JSON") } }
        rig.engine.stop()
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", "late"))
        await rig.engine.advance(to: 300)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(rig.engine.boardVersion, 0)
        XCTAssertEqual(rig.engine.moveRequestCount, 1)
        XCTAssertNil(rig.engine.retryAt)
        try await rig.engine.closeArchive()
    }

    func testFinalSummaryKeepsBoardVisibleUntilSpeechEnds() async throws {
        let rig = try makeRig()
        rig.engine.learningTimeout = 0.03
        var checkpoint = rig.engine.checkpoint
        for move in ["f2f3", "e7e5", "g2g4"] { _ = checkpoint.referee.submit(rawMove: move, taunt: "") }
        rig.engine.restore(checkpoint)
        let voice = try XCTUnwrap(rig.engine.voice as? ScriptedVoice)
        voice.hold = true
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("JSON") } }
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("d8h4", ""))
        try await waitUntil { rig.chat.calls.contains { $0.user.contains("Result:") } }
        XCTAssertEqual(rig.engine.phase, "summary")
        XCTAssertEqual(rig.engine.finalCards, 0)
        XCTAssertNil(rig.engine.picture.banner)
        let finalFEN = rig.engine.referee.position.fen
        rig.chat.fulfill(where: { $0.user.contains("Result:") }, body: "ChatGPT wins. The prognosis was less optimistic than the opening.")
        try await waitUntil { voice.isSpeaking }
        XCTAssertTrue(rig.engine.picture.line.contains("prognosis"), "Show the verdict while it is spoken")
        await rig.engine.advance(to: 60)
        XCTAssertEqual(rig.engine.finalCards, 0, "Even a long summary must precede the countdown")
        XCTAssertEqual(rig.engine.referee.position.fen, finalFEN)
        XCTAssertNotNil(rig.engine.scene.node(named: "piece-queen-h4"))
        voice.release()
        try await waitUntil { rig.engine.finalCards == 1 }
        XCTAssertEqual(rig.engine.speech.filter { $0.kind == .final }.count, 1)
        await rig.engine.advance(to: 89)
        XCTAssertEqual(rig.engine.phase, "final")
        await rig.engine.advance(to: 90)
        XCTAssertEqual(rig.engine.phase, "finished")
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testStoppingDuringSummaryPreventsLateFinalCard() async throws {
        let rig = try makeRig()
        var checkpoint = rig.engine.checkpoint
        for move in ["f2f3", "e7e5", "g2g4"] { _ = checkpoint.referee.submit(rawMove: move, taunt: "") }
        rig.engine.restore(checkpoint)
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("JSON") } }
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("d8h4", ""))
        try await waitUntil { rig.chat.calls.contains { $0.user.contains("Result:") } }
        rig.engine.stop()
        rig.chat.fulfill(where: { $0.user.contains("Result:") }, body: "Late verdict.")
        try await Task.sleep(nanoseconds: 30_000_000)
        await rig.engine.advance(to: 100)
        XCTAssertEqual(rig.engine.finalCards, 0)
        XCTAssertFalse(rig.engine.speech.contains { $0.kind == .final })
        try await rig.engine.closeArchive()
    }

    func testMatePublishesResultImmediatelyEvenIfFinalHostNeverAnswers() async throws {
        let rig = try makeRig()
        var results: [GameEnd] = []
        rig.engine.onGameEnded = { results.append($0) }
        rig.engine.hostTimeout = 0.03
        rig.engine.learningTimeout = 0.03
        try await rig.engine.start(at: 0)
        for (index, move) in ["f2f3", "e7e5", "g2g4", "d8h4"].enumerated() {
            try await waitUntil { rig.chat.calls.filter { $0.system.contains("JSON") }.count == index + 1 }
            rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove(move, ""))
        }
        try await waitUntil { rig.engine.finalCards == 1 }
        XCTAssertEqual(results, [.checkmate(winner: .black)])
        XCTAssertEqual(rig.engine.picture.banner, "ChatGPT WINS")
        await rig.engine.advance(to: 29)
        XCTAssertEqual(rig.engine.phase, "final")
        await rig.engine.advance(to: 30)
        XCTAssertEqual(rig.engine.phase, "finished")
        XCTAssertEqual(results.count, 1)
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testCheckpointIsSavedBeforeHostResponseAndRestoresNextPlayer() async throws {
        let first = try makeRig()
        var saved: GameCheckpoint?
        first.engine.onStateChanged = { saved = first.engine.checkpoint }
        try await first.engine.start(at: 47)
        try await waitUntil { first.chat.calls.contains { $0.system.contains("JSON") } }
        first.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", "Opening"))
        try await waitUntil { saved?.referee.accepted.count == 1 }
        let data = try JSONEncoder().encode(XCTUnwrap(saved))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("CHESSARENA-SECRET-KEY"))
        let checkpoint = try JSONDecoder().decode(GameCheckpoint.self, from: data)
        first.engine.stop()
        try await first.engine.closeArchive()

        let restored = try makeRig()
        restored.engine.restore(checkpoint)
        try await restored.engine.start(at: checkpoint.elapsed)
        try await waitUntil { restored.chat.calls.contains { $0.system.contains("JSON") } }
        let call = try XCTUnwrap(restored.chat.calls.first)
        XCTAssertTrue(call.system.contains("You are Black"))
        XCTAssertTrue(call.user.contains(checkpoint.referee.position.fen))
        XCTAssertTrue(call.user.contains("e4"))
        XCTAssertEqual(restored.engine.boardVersion, 1)
        XCTAssertEqual(restored.engine.clock, 47)
        XCTAssertEqual(restored.engine.referee.accepted.count, 1)
        XCTAssertEqual(restored.engine.picture.replies, checkpoint.picture.replies)
        XCTAssertTrue(restored.engine.archive.pgnText().contains("1. e4"))
        restored.engine.stop()
        try await restored.engine.closeArchive()
    }

    func testRestoredFinishedGameDoesNotSendMoveOrPublishResultAgain() async throws {
        var referee = Referee()
        for move in ["f2f3", "e7e5", "g2g4", "d8h4"] { _ = referee.submit(rawMove: move, taunt: "") }
        let rig = try makeRig()
        var checkpoint = rig.engine.checkpoint
        checkpoint.referee = referee
        checkpoint.elapsed = 100
        rig.engine.restore(checkpoint)
        var results = 0
        rig.engine.onGameEnded = { _ in results += 1 }
        try await rig.engine.start(at: 100)
        await rig.engine.advance(to: 131)
        XCTAssertTrue(rig.chat.calls.isEmpty)
        XCTAssertEqual(results, 0)
        XCTAssertEqual(rig.engine.picture.banner, "ChatGPT WINS")
        XCTAssertTrue(rig.engine.archive.pgnText().contains("Qh4#"))
        XCTAssertTrue(rig.engine.archive.pgnText().contains("0-1"))
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    private func makeRig(
        whitePlayer: PlayerConfiguration? = nil, blackPlayer: PlayerConfiguration? = nil,
        hostPlayer: PlayerConfiguration? = nil, gameMemory: GameMemory = GameMemory()
    ) throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = MatchArchive(directory: directory,
                                   whiteName: whitePlayer?.provider.rawValue ?? "Grok",
                                   blackName: blackPlayer?.provider.rawValue ?? "ChatGPT")
        let chat = ScriptedChat()
        let secret = "CHESSARENA-SECRET-KEY-9f3c2a7b"
        let white = whitePlayer?.seat(side: .white, grokKey: "grok-key", chatKey: "openai-key") ?? Seat.defaultWhite(apiKey: secret)
        let black = blackPlayer?.seat(side: .black, grokKey: "grok-key", chatKey: "openai-key") ?? Seat.defaultBlack(apiKey: secret)
        let host = hostPlayer?.seat(side: .white, grokKey: "grok-key", chatKey: "openai-key")
            ?? Seat(name: "Host", baseURL: ModelCatalog.grokAPI, model: ModelCatalog.grokModel, apiKey: secret, side: .white)
        let engine = MatchEngine(
            scene: BoardScene(),
            voice: ScriptedVoice(),
            transport: chat,
            archive: archive,
            white: white,
            black: black,
            host: host,
            gameMemory: gameMemory
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
