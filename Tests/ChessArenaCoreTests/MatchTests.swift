import AVFoundation
import XCTest
@testable import ChessArenaCore

@MainActor
final class MatchTests: XCTestCase {
    func testFreshMatchResetsReusedBoardBeforeRequestingOpeningMove() async throws {
        let rig = try makeRig()
        let position = Position.standard()
        let move = try XCTUnwrap(position.parseUCI("e2e4"))
        rig.engine.scene.animate(move: move, positionAfter: position.applying(move), side: .white, duration: 30)
        rig.engine.scene.setThinking(.black)
        XCTAssertNotNil(rig.engine.scene.node(named: "trail-cold-e2e4"))

        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        XCTAssertEqual(rig.engine.referee.position, .standard())
        XCTAssertTrue(rig.chat.calls[0].user.contains(Position.standard().fen))
        XCTAssertTrue(rig.engine.referee.accepted.isEmpty)
        XCTAssertFalse(rig.engine.scene.isAnimating)
        XCTAssertNil(rig.engine.scene.node(named: "trail-cold-e2e4"))
        XCTAssertNil(rig.engine.scene.node(named: "piece-pawn-e4"))
        XCTAssertNotNil(rig.engine.scene.node(named: "piece-pawn-e2"))
        XCTAssertNil(rig.engine.scene.node(named: "pulse-black"))
        XCTAssertNotNil(rig.engine.scene.node(named: "pulse-white"))
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testDeepSeekRetryUsesUpdatedConfigurationWithoutChangingPositionOrNotes() async throws {
        let rig = try makeRig(whitePlayer: .init(provider: .deepseek))
        var saved = rig.engine.checkpoint
        saved.whiteSelfNotes = "ACCEPTED_PLAN"
        rig.engine.restore(saved)
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        let fen = rig.engine.referee.position.fen
        rig.chat.fail(where: { $0.route == .deepseek }, error: .http(status: 402, reason: .balance))
        try await waitUntil { rig.engine.paused }
        XCTAssertNotNil(rig.engine.retryAt)
        XCTAssertEqual(rig.engine.referee.position.fen, fen)
        XCTAssertTrue(rig.engine.pauseReason?.contains("балансе DeepSeek") == true)
        rig.engine.white.apiKey = "corrected-key"
        rig.engine.white.model = "deepseek-flash"
        await rig.engine.advance(to: try XCTUnwrap(rig.engine.retryAt))
        try await waitUntil { rig.chat.calls.count == 2 }
        let retry = try XCTUnwrap(rig.chat.calls.last)
        XCTAssertEqual(retry.apiKey, "corrected-key")
        XCTAssertEqual(retry.model, "deepseek-flash")
        XCTAssertEqual(retry.route, .deepseek)
        XCTAssertTrue(retry.user.contains(fen))
        XCTAssertEqual(retry.selfNotes, "ACCEPTED_PLAN")
        rig.chat.fail(where: { $0.apiKey == "corrected-key" }, error: .unreadable)
        try await waitUntil { rig.chat.calls.count == 3 }
        XCTAssertEqual(rig.engine.checkpoint.whiteSelfNotes, "ACCEPTED_PLAN")
        XCTAssertEqual(rig.engine.referee.position.fen, fen)
        rig.engine.stop()
        rig.chat.fulfill(where: { $0.route == .deepseek }, body: #"{"move":"e2e4","taunt":"LATE","self_notes":"LATE_PLAN"}"#)
        await rig.engine.advance(to: 300)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(rig.engine.boardVersion, 0)
        XCTAssertEqual(rig.engine.checkpoint.whiteSelfNotes, "ACCEPTED_PLAN")
        XCTAssertTrue(rig.engine.spokenTaunts.isEmpty)
        XCTAssertNil(rig.engine.retryAt)
        try await rig.engine.closeArchive()
    }

    func testDeepSeekPersonaAndArchiveUseSanitizedFinalAnswer() async throws {
        var white = PlayerConfiguration(provider: .deepseek).seat(side: .white, keys: rigKeys)
        var personas = PersonaAssignments.initial
        white.persona = personas.assign(provider: .deepseek, model: white.model)
        let rig = try makeRig(whiteSeat: white)
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        XCTAssertTrue(rig.engine.speech.first?.text.contains("DeepSeek") == true)
        let response: [String: Any] = ["choices": [["finish_reason": "stop", "message": [
            "reasoning_content": "INTERNAL_REASONING", "content": #"{"move":"e2e4","taunt":"Hello deepseek-key","self_notes":"Plan deepseek-key"}"#]]]]
        let data = try JSONSerialization.data(withJSONObject: response)
        let text = DeepSeekAPI.redact(try DeepSeekAPI.text(from: data), key: white.apiKey)
        rig.chat.fulfill(where: { $0.route == .deepseek }, body: text)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Played.")
        try await waitUntil { rig.engine.boardVersion == 1 && rig.engine.spokenTaunts.count == 1 }
        XCTAssertEqual(rig.engine.picture.whiteName, "DeepSeek")
        let voice = try XCTUnwrap(rig.engine.voice as? ScriptedVoice)
        XCTAssertEqual(voice.spoken.first { $0.kind == .taunt }?.profile, .persona(try XCTUnwrap(white.persona)))
        XCTAssertEqual(rig.engine.checkpoint.whiteSelfNotes, "Plan [REDACTED]")
        rig.engine.stop()
        try await rig.engine.closeArchive()
        let pgn = try String(contentsOf: rig.engine.archive.pgnURL)
        let journal = try String(contentsOf: rig.engine.archive.journalURL)
        XCTAssertTrue(pgn.contains("DeepSeek"))
        XCTAssertTrue(pgn.contains("e4"))
        for value in [pgn, journal, rig.engine.picture.broadcastText] {
            XCTAssertFalse(value.contains("INTERNAL_REASONING"))
            XCTAssertFalse(value.contains(white.apiKey))
        }
    }

    func testCommentaryKeepsTheCompleteLastSentenceBeyondPromptWordLimit() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", ""))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        let text = Array(repeating: "word", count: 36).joined(separator: " ") + " completes this sentence. And the final sentence remains intact."
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: text)
        try await waitUntil { rig.engine.speech.contains { $0.kind == .move } }
        XCTAssertEqual(rig.engine.speech.last?.text, text)
        let voice = try XCTUnwrap(rig.engine.voice as? ScriptedVoice)
        XCTAssertEqual(voice.prepared.last?.text, text)
        rig.engine.stop(); try await rig.engine.closeArchive()
    }

    func testSlowSynthesisKeepsBoardAndThinkingUntilPlaybackStarts() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        let voice = try XCTUnwrap(rig.engine.voice as? ScriptedVoice)
        voice.holdPreparation = true
        try await waitUntil { rig.chat.calls.count == 1 }
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", ""))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Ready commentary.")
        try await waitUntil { voice.prepared.contains { $0.kind == .move } }
        await rig.engine.advance(to: 11)
        XCTAssertEqual(rig.engine.boardVersion, 0)
        XCTAssertEqual(rig.engine.checkpoint.referee.position, Position.standard())
        XCTAssertNil(rig.engine.scene.node(named: "piece-pawn-e4"))
        XCTAssertEqual(rig.engine.picture.thinkingSide, .white)
        var beganTogether = false
        voice.onSpeaking = {
            if voice.spoken.last?.kind == .move {
                beganTogether = rig.engine.boardVersion == 1 && rig.engine.scene.node(named: "piece-pawn-e4") != nil
            }
        }
        voice.holdPreparation = false; voice.releasePreparation()
        try await waitUntil { rig.engine.speech.contains { $0.kind == .move } }
        XCTAssertTrue(beganTogether)
        XCTAssertEqual(rig.engine.speech.last?.clock, 11)
        rig.engine.stop(); try await rig.engine.closeArchive()
    }

    func testNextAnswerAndSynthesisOverlapPlayerLineButWaitForHostToFinish() async throws {
        var white = Seat.defaultWhite(apiKey: "k"); white.persona = .burr
        var black = Seat.defaultBlack(apiKey: "k"); black.persona = .gervais
        let rig = try makeRig(whiteSeat: white, blackSeat: black)
        try await rig.engine.start(at: 0)
        let voice = try XCTUnwrap(rig.engine.voice as? ScriptedVoice)
        voice.hold = true
        try await waitUntil { rig.chat.calls.count == 1 }
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", "First taunt."))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "First commentary.")
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("You are Black") } }
        XCTAssertTrue(voice.isSpeaking)
        XCTAssertEqual(voice.spoken.last?.text, "First taunt.")
        rig.chat.fulfill(where: { $0.system.contains("You are Black") }, body: jsonMove("e7e5", "Second taunt."))
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("already on the board") }.count == 2 }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Second commentary.")
        try await waitUntil { voice.prepared.contains { $0.text == "Second taunt." } }
        XCTAssertEqual(rig.engine.boardVersion, 1)
        XCTAssertNil(rig.engine.scene.node(named: "piece-pawn-e5"))
        XCTAssertEqual(voice.spoken.last?.text, "First taunt.")
        voice.release()
        try await waitUntil { voice.spoken.last?.text == "First commentary." }
        XCTAssertEqual(rig.engine.boardVersion, 1)
        voice.release()
        try await waitUntil { voice.spoken.last?.text == "Second taunt." }
        XCTAssertEqual(rig.engine.boardVersion, 2)
        XCTAssertNotNil(rig.engine.scene.node(named: "piece-pawn-e5"))
        XCTAssertEqual(rig.engine.spokenTaunts.first?.boardVersion, 1)
        rig.engine.stop(); try await rig.engine.closeArchive()
    }

    func testRepeatDiscardsPreparedMoveWithoutInterruptingCurrentCommentary() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        let voice = try XCTUnwrap(rig.engine.voice as? ScriptedVoice)
        voice.hold = true
        try await waitUntil { rig.chat.calls.count == 1 }
        rig.chat.fulfill(where: { $0.system.contains("You are White") }, body: jsonMove("e2e4", ""))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Still speaking.")
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("You are Black") } }
        rig.chat.fulfill(where: { $0.system.contains("You are Black") }, body: jsonMove("e7e5", ""))
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("already on the board") }.count == 2 }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Discard this prepared move.")
        try await waitUntil { voice.prepared.contains { $0.text == "Discard this prepared move." } }
        XCTAssertTrue(rig.engine.canRepeatPlayerRequest)
        rig.engine.repeatPlayerRequest()
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("You are Black") }.count == 2 }
        XCTAssertTrue(voice.isSpeaking)
        XCTAssertEqual(voice.spoken.last?.text, "Still speaking.")
        rig.chat.fulfill(where: { $0.system.contains("You are Black") }, body: jsonMove("d7d5", ""))
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("already on the board") }.count == 3 }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Replacement move.")
        try await waitUntil { voice.prepared.contains { $0.text == "Replacement move." } }
        XCTAssertEqual(rig.engine.boardVersion, 1)
        voice.hold = false; voice.release()
        try await waitUntil { rig.engine.boardVersion == 2 }
        XCTAssertEqual(rig.engine.referee.accepted.last?.move.uci, "d7d5")
        XCTAssertFalse(voice.spoken.contains { $0.text == "Discard this prepared move." })
        XCTAssertNil(rig.engine.scene.node(named: "piece-pawn-e5"))
        rig.engine.stop(); try await rig.engine.closeArchive()
    }

    func testWaitingCommentaryLongerThanTwentySecondsFinishesBeforeReadyMove() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        let voice = try XCTUnwrap(rig.engine.voice as? ScriptedVoice)
        voice.hold = true
        await rig.engine.advance(to: 20)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("Do not name a move") } }
        rig.chat.fulfill(where: { $0.system.contains("Do not name a move") }, body: "A long waiting commentary.")
        try await waitUntil { voice.isSpeaking }
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", ""))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Prepared move.")
        try await waitUntil { voice.prepared.contains { $0.kind == .move } }
        try await Task.sleep(nanoseconds: 20_300_000_000)
        XCTAssertTrue(voice.isSpeaking, "A playback must outlive the old twenty-second cutoff")
        XCTAssertEqual(voice.spoken.last?.kind, .wait)
        XCTAssertEqual(rig.engine.boardVersion, 0)
        voice.hold = false; voice.release()
        try await waitUntil { rig.engine.boardVersion == 1 }
        XCTAssertEqual(voice.spoken.map(\.kind), [.intro, .wait, .move])
        rig.engine.stop(); try await rig.engine.closeArchive()
    }

    func testStopDuringAudioPreparationNeverCommitsCandidateMove() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        let voice = try XCTUnwrap(rig.engine.voice as? ScriptedVoice)
        voice.holdPreparation = true
        try await waitUntil { rig.chat.calls.count == 1 }
        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", ""))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Late audio.")
        try await waitUntil { voice.prepared.contains { $0.kind == .move } }
        rig.engine.stop()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(rig.engine.boardVersion, 0)
        XCTAssertEqual(rig.engine.checkpoint.referee.position, Position.standard())
        XCTAssertFalse(voice.spoken.contains { $0.kind == .move })
        try await rig.engine.closeArchive()
    }

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
        try await checkAdviceIsolation(provider: .grok)
        try await checkAdviceIsolation(provider: .deepseek)
    }

    private func checkAdviceIsolation(provider: NeuralProvider) async throws {
        let config = PlayerConfiguration(provider: provider)
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
        try await waitUntil { rig.chat.calls.contains { $0.user.contains("Result:") } }
        rig.chat.fulfill(where: { $0.user.contains("Result:") }, body: "Black wins.")
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("Post-game self-review") }.count == 2 }
        let reviews = rig.chat.calls.filter { $0.system.contains("Post-game self-review") }
        for call in reviews {
            let white = call.user.contains("You played: White")
            XCTAssertEqual(call.gameAdvice, white ? "OLD_WHITE_LESSON" : "OLD_BLACK_LESSON")
            XCTAssertEqual(call.selfNotes, white ? "WHITE_TURN_NOTE" : "BLACK_TURN_NOTE")
            XCTAssertEqual(call.responseFormat, .text)
            XCTAssertEqual(call.effort, "high")
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
        try await checkFailedAdvice(provider: .grok)
        try await checkFailedAdvice(provider: .deepseek)
    }

    private func checkFailedAdvice(provider: NeuralProvider) async throws {
        let rig = try makeRig(whitePlayer: .init(provider: provider), blackPlayer: .init(provider: provider))
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
        try await waitUntil { rig.chat.calls.contains { $0.user.contains("Result:") } }
        rig.chat.fulfill(where: { $0.user.contains("Result:") }, body: "Black wins.")
        try await waitUntil { rig.chat.calls.filter { $0.system.contains("Post-game self-review") }.count == 2 }
        rig.chat.fail(where: { $0.user.contains("You played: White") }, error: .unreadable)
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
        try await waitUntil { rig.chat.calls.contains { $0.user.contains("Result:") } }
        rig.chat.fulfill(where: { $0.user.contains("Result:") }, body: "Black wins.")
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
        for provider in [NeuralProvider.grok, .chatGPT, .claude] {
            var host = PlayerConfiguration(provider: provider)
            host.model = "selected-commentator-model"
            let rig = try makeRig(hostPlayer: host)
            try await rig.engine.start(at: 0)
            try await waitUntil { rig.chat.calls.count == 1 }
            rig.chat.fulfill(where: { $0.system.contains("Reply with JSON") },
                             body: #"{"move":"e2e4","taunt":"Go.","self_notes":"PRIVATE_PLAYER_PLAN"}"#)
            try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
            let call = try XCTUnwrap(rig.chat.calls.last)
            XCTAssertEqual(call.url, provider.baseURL.appendingPathComponent(provider == .claude ? "messages" : "chat/completions"))
            XCTAssertEqual(call.model, "selected-commentator-model")
            XCTAssertEqual(call.apiKey, expectedKey(provider))
            XCTAssertEqual(call.route, rigKeys.route(for: provider))
            XCTAssertEqual(call.effort, "low")
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
        try await checkNotesIsolation(provider: .grok)
        try await checkNotesIsolation(provider: .deepseek)
    }

    private func checkNotesIsolation(provider: NeuralProvider) async throws {
        // Even two seats using the same provider and model must not share notes.
        let config = PlayerConfiguration(provider: provider)
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
            XCTAssertEqual(rig.engine.picture.thinkingSide, index.isMultiple(of: 2) ? .white : .black)
            XCTAssertEqual(rig.engine.picture.thinkingSelfNotes, call.selfNotes)
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

        let restored = try makeRig(whitePlayer: config, blackPlayer: config)
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
        try await waitUntil { restored.chat.calls.contains { $0.system.contains("already on the board") } }
        restored.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Played.")
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
                XCTAssertEqual(opening.apiKey, expectedKey(whiteProvider))
                XCTAssertEqual(opening.model, "white-selected-model")
                XCTAssertEqual(opening.route, rigKeys.route(for: whiteProvider))
                if whiteProvider == .lc0 { XCTAssertEqual(opening.chessPosition, LC0Position(referee: Referee())) }
                XCTAssertEqual(opening.effort, "high")
                XCTAssertEqual(opening.responseFormat, .jsonObject)
                rig.chat.fulfill(where: { $0.system.contains("You are White") }, body: jsonMove("e2e4", "Go."))
                try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
                let host = try XCTUnwrap(rig.chat.calls.first { $0.system.contains("already on the board") })
                XCTAssertEqual(host.url.host, "api.x.ai")
                XCTAssertEqual(host.model, ModelCatalog.grokModel)
                rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "White starts.")
                try await waitUntil { rig.chat.calls.contains { $0.system.contains("You are Black") } }
                let reply = try XCTUnwrap(rig.chat.calls.first { $0.system.contains("You are Black") })
                XCTAssertEqual(reply.url.host, blackProvider.baseURL.host)
                XCTAssertEqual(reply.apiKey, expectedKey(blackProvider))
                XCTAssertEqual(reply.model, "black-selected-model")
                XCTAssertEqual(reply.route, rigKeys.route(for: blackProvider))
                if blackProvider == .lc0 {
                    XCTAssertEqual(reply.chessPosition?.moves, ["e2e4"])
                    XCTAssertTrue(reply.chessPosition?.legalMoves.contains("e7e5") == true)
                }
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

    func testClaudeRefusalPausesWithoutRetryAndHTTPErrorsRetryLikeOtherProviders() async throws {
        let rig = try makeRig(whitePlayer: PlayerConfiguration(provider: .claude))
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        let original = rig.engine.referee.position.fen
        XCTAssertEqual(rig.chat.calls[0].route, .anthropic)
        rig.chat.fail(where: { $0.route == .anthropic }, error: .refused)
        try await waitUntil { rig.engine.paused }
        XCTAssertNil(rig.engine.retryAt)
        XCTAssertTrue(rig.engine.pauseReason?.contains("отказалась") == true)
        await rig.engine.advance(to: 1000)
        XCTAssertEqual(rig.engine.moveRequestCount, 1)
        XCTAssertEqual(rig.engine.referee.position.fen, original)
        var referee = rig.engine.referee
        if case .rejected(_, let attempt) = referee.submit(rawMove: "invalid", taunt: "") {
            XCTAssertEqual(attempt, 1)
        } else { XCTFail("A refusal must not count as an illegal move") }
        rig.engine.white.model = "claude-sonnet-5-5"
        rig.engine.resume()
        try await waitUntil { rig.chat.calls.count == 2 }
        XCTAssertEqual(rig.chat.calls.last?.model, "claude-sonnet-5-5")
        XCTAssertTrue(rig.chat.calls.last?.user.contains(original) == true)
        rig.chat.fail(where: { $0.route == .anthropic && $0.model == "claude-sonnet-5-5" }, error: .http(status: 401, reason: .authentication))
        try await waitUntil { rig.engine.paused }
        XCTAssertNotNil(rig.engine.retryAt, "HTTP errors keep the shared automatic retry")
        XCTAssertTrue(rig.engine.pauseReason?.contains("HTTP 401") == true)
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testClaudeSubscriptionSeatUsesLocalCLIWithoutKeyAndPausesWithoutRetry() async throws {
        var keys = rigKeys; keys.claudeAccess = .subscription
        let white = PlayerConfiguration(provider: .claude).seat(side: .white, keys: keys)
        let rig = try makeRig(whiteSeat: white)
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        let call = try XCTUnwrap(rig.chat.calls.first)
        XCTAssertEqual(call.route, .claudeCLI)
        XCTAssertEqual(call.url, ClaudeCLI.localURL)
        XCTAssertEqual(call.apiKey, "")
        XCTAssertEqual(call.model, ModelCatalog.claudeModel)
        let original = rig.engine.referee.position.fen
        rig.chat.fail(where: { $0.route == .claudeCLI }, error: .claudeCLI(.quota))
        try await waitUntil { rig.engine.paused }
        XCTAssertNil(rig.engine.retryAt)
        XCTAssertTrue(rig.engine.pauseReason?.contains("подписки") == true)
        await rig.engine.advance(to: 1000)
        XCTAssertEqual(rig.engine.moveRequestCount, 1)
        XCTAssertEqual(rig.engine.referee.position.fen, original)
        XCTAssertEqual(rig.engine.picture.whiteName, "Claude")
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testNewGameOpensWithGreetingLineupAndPersonaPromptsAndTauntAuthor() async throws {
        var white = PlayerConfiguration(provider: .claude).seat(side: .white, keys: rigKeys)
        white.persona = .burr
        var black = Seat.defaultBlack(apiKey: "k")
        black.persona = .gervais
        let rig = try makeRig(whiteSeat: white, blackSeat: black)
        rig.engine.language = .english
        try await rig.engine.start(at: 0)
        let intro = try XCTUnwrap(rig.engine.speech.first)
        XCTAssertEqual(intro.kind, .intro)
        XCTAssertTrue(intro.text.contains("welcome to Chess Arena"))
        XCTAssertTrue(intro.text.contains("Playing White: Claude, model claude-opus-5-5."), intro.text)
        XCTAssertTrue(intro.text.contains("Playing Black: ChatGPT, model chat-latest."), intro.text)
        XCTAssertTrue(rig.engine.archive.journal.contains { $0.kind == "intro" })
        try await waitUntil { rig.chat.calls.count == 1 }
        let request = try XCTUnwrap(rig.chat.calls.first)
        XCTAssertTrue(request.system.contains("Blunt, irritated, no apologies".lowercased()))
        XCTAssertTrue(request.system.contains("address it to your opponent"))
        XCTAssertTrue(request.system.contains("aimed at your opponent"))
        XCTAssertFalse(request.system.contains("Bill Burr"))
        rig.chat.fulfill(where: { $0.system.contains("Reply with JSON") }, body: jsonMove("e2e4", "Nice opening. Shame about everything after it."))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "Fine.")
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("You are Black") } }
        try await waitUntil { rig.engine.spokenTaunts.count == 1 }
        XCTAssertEqual(rig.engine.picture.tauntSide, .white)
        XCTAssertEqual(rig.engine.picture.taunt, "Nice opening. Shame about everything after it.")
        XCTAssertNil(rig.engine.picture.tauntPersona)
        let voice = try XCTUnwrap(rig.engine.voice as? ScriptedVoice)
        XCTAssertEqual(voice.spoken.first?.profile, .host, "the greeting is the host's")
        XCTAssertEqual(voice.spoken.first { $0.kind == .move }?.profile, .host)
        let taunt = try XCTUnwrap(voice.spoken.first { $0.kind == .taunt })
        XCTAssertEqual(taunt.profile, .persona(.burr))
        XCTAssertEqual(taunt.text, "Nice opening. Shame about everything after it.")
        let order = voice.spoken.map(\.kind)
        XCTAssertLessThan(order.firstIndex(of: .taunt)!, order.firstIndex(of: .move)!, "player line with the move, then the host comment")
        XCTAssertFalse(rig.engine.speech.contains { $0.kind == .taunt }, "taunts stay out of the host speech log")
        XCTAssertEqual(rig.engine.archive.journal.filter { $0.kind == "taunt" }.count, 1, "the journal keeps one taunt entry per move")
        XCTAssertTrue(rig.chat.calls.last?.system.contains("polite British cruelty") == true)
        XCTAssertTrue(rig.chat.calls.last?.system.contains("You are Black") == true)
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testThinkCountdownFollowsTheMoveRequestAndResetsOnRepeat() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        XCTAssertEqual(rig.engine.picture.thinkingSide, .white)
        XCTAssertEqual(rig.engine.picture.thinkSecondsLeft, Int(RequestTimeouts.player))
        await rig.engine.advance(to: 12.4)
        XCTAssertEqual(rig.engine.picture.thinkSecondsLeft, Int(RequestTimeouts.player) - 12, "rounded up to whole seconds")
        rig.engine.repeatPlayerRequest()
        XCTAssertEqual(rig.engine.picture.thinkSecondsLeft, Int(RequestTimeouts.player), "a repeated request restarts the countdown")
        try await waitUntil { rig.chat.calls.count == 2 }
        // The cancelled first attempt is still pending in the script; fail it first, then the live repeat.
        rig.chat.fail(where: { $0.system.contains("You are White") }, error: .http(status: 500, reason: .server))
        rig.chat.fail(where: { $0.system.contains("You are White") }, error: .http(status: 500, reason: .server))
        try await waitUntil { rig.engine.paused }
        XCTAssertNil(rig.engine.picture.thinkSecondsLeft, "no countdown while paused")
        XCTAssertNil(rig.engine.picture.thinkingSide)
        await rig.engine.advance(to: 20)
        try await waitUntil { rig.chat.calls.count == 3 }
        XCTAssertEqual(rig.engine.picture.thinkSecondsLeft, Int(RequestTimeouts.player))
        rig.chat.fulfill(where: { $0.system.contains("You are White") }, body: jsonMove("e2e4", ""))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        XCTAssertEqual(rig.engine.referee.accepted.count, 0)
        XCTAssertNotNil(rig.engine.picture.thinkSecondsLeft, "preparation remains part of thinking")
        let data = try JSONEncoder().encode(rig.engine.picture)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "thinkSecondsLeft")
        XCTAssertNil(try JSONDecoder().decode(BroadcastPicture.self, from: JSONSerialization.data(withJSONObject: legacy)).thinkSecondsLeft)
        rig.engine.stop()
        try await rig.engine.closeArchive()
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

    func testCommentaryIsPreparedBeforeTheMoveAndWaitsOnce() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        XCTAssertEqual(rig.engine.picture.thinkingSide, .white)
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("JSON") } }
        XCTAssertTrue(rig.engine.speech.filter { $0.kind == .move }.isEmpty)
        await rig.engine.advance(to: 19)
        XCTAssertTrue(rig.engine.speech.filter { $0.kind == .wait }.isEmpty)

        rig.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", "After you."))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        XCTAssertEqual(rig.engine.boardVersion, 0)
        XCTAssertEqual(rig.engine.hostBoardVersions, [1])
        XCTAssertNil(rig.engine.scene.node(named: "piece-pawn-e4"))
        XCTAssertEqual(rig.engine.picture.thinkingSide, .white)
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "The pawn has left home and already looks unsure.")
        try await waitUntil { rig.engine.speech.contains { $0.kind == .move } }
        XCTAssertNotNil(rig.engine.scene.node(named: "piece-pawn-e4"))
        XCTAssertEqual(rig.engine.picture.replies.map(\.side), [.white])
        XCTAssertEqual(rig.engine.picture.replies.map(\.name), ["Grok"])
        let reply = try XCTUnwrap(rig.engine.picture.replies.first)
        XCTAssertTrue(reply.text.contains("e2e4"))
        XCTAssertTrue(reply.text.contains("After you."))
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
        try await waitUntil { cancelled.engine.phase == "preparing" }
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
        try await waitUntil { rig.engine.phase == "preparing" }
        XCTAssertEqual(rig.engine.boardVersion, 0)
        XCTAssertTrue(rig.engine.canRepeatPlayerRequest)
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
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "White played.")
        try await waitUntil { rig.engine.boardVersion == 1 }
        XCTAssertEqual(rig.engine.referee.accepted.first?.move.uci, "e2e4")
        XCTAssertTrue(log.entries.contains { $0.response?.contains("e2e4") == true && $0.status == .received })
        XCTAssertEqual(log.entries.first { $0.id == failedID }?.status, .failed)
        XCTAssertFalse(log.entries.contains { $0.response?.contains("stale") == true })
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testCommentatorKeepsOneStyleAndFallbacksVaryAfterRestore() async throws {
        let rig = try makeRig()
        try await rig.engine.start(at: 0)
        for (index, move) in ["e2e4", "e7e5", "g1f3", "b8c6"].enumerated() {
            try await waitUntil { rig.chat.calls.filter { $0.system.contains("Reply with JSON") }.count == index + 1 }
            rig.chat.fulfill(where: { $0.system.contains("Reply with JSON") }, body: jsonMove(move, ""))
            try await waitUntil { rig.chat.calls.filter { $0.system.contains("already on the board") }.count == index + 1 }
            let host = try XCTUnwrap(rig.chat.calls.last)
            XCTAssertTrue(host.system.contains("conversational observational humor"))
            XCTAssertFalse(host.system.contains("House")); XCTAssertFalse(host.system.contains("Carlin"))
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
        XCTAssertTrue(waiting.system.contains("conversational observational humor"))
        restored.chat.fail(where: { $0.system.contains("Do not name a move") }, error: .transport)
        try await waitUntil { restored.engine.speech.contains { $0.kind == .wait } }
        let waitingLines = (0..<8).map { CommentaryStyle.zadornov.fallback(for: .waiting, language: .english, variation: $0) }
        XCTAssertTrue(waitingLines.contains(restored.engine.speech.last?.text ?? ""), restored.engine.speech.last?.text ?? "")
        XCTAssertFalse(restored.engine.speech.contains { $0.kind == .intro }, "a restored game is not greeted again")
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
            XCTAssertEqual(rig.engine.speech.last?.text, language == .russian ? "Фигура переехала на одну клетку, а планов — как после покупки новой квартиры." : "One piece changed squares, with enough plans to furnish a new apartment.")
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
        XCTAssertEqual(rig.engine.phase, "preparing")
        XCTAssertEqual(rig.engine.finalCards, 0)
        XCTAssertNil(rig.engine.picture.banner)
        let previousFEN = rig.engine.referee.position.fen
        rig.chat.fulfill(where: { $0.user.contains("Result:") }, body: "ChatGPT wins. The prognosis was less optimistic than the opening.")
        try await waitUntil { voice.isSpeaking }
        let finalFEN = rig.engine.referee.position.fen
        XCTAssertNotEqual(finalFEN, previousFEN)
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

    func testCheckpointChangesOnlyWhenPreparedMoveIsPresentedAndRestoresNextPlayer() async throws {
        let first = try makeRig()
        var saved: GameCheckpoint?
        first.engine.onStateChanged = { saved = first.engine.checkpoint }
        try await first.engine.start(at: 47)
        try await waitUntil { first.chat.calls.contains { $0.system.contains("JSON") } }
        first.chat.fulfill(where: { $0.system.contains("JSON") }, body: jsonMove("e2e4", "Opening"))
        try await waitUntil { first.chat.calls.contains { $0.system.contains("already on the board") } }
        XCTAssertEqual(saved?.referee.accepted.count, 0, "A pending presentation is not a shown move")
        first.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "White played.")
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

    func testOrdinaryTauntIsSuppressedAndRejectedAnswerDoesNotRedraw() async throws {
        var white = Seat.defaultWhite(apiKey: "k"); white.persona = .burr
        let rig = try makeRig(whiteSeat: white)
        var draws = 0
        rig.engine.tauntDraw = { draws += 1; return 20 }
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        XCTAssertTrue(rig.chat.calls[0].user.contains("An ordinary move requires silence"))
        rig.chat.fulfill(where: { $0.system.contains("You are White") }, body: jsonMove("e2e5", "Rejected joke."))
        try await waitUntil { rig.chat.calls.count == 2 }
        XCTAssertEqual(draws, 1)
        rig.chat.fulfill(where: { $0.system.contains("You are White") }, body: jsonMove("e2e4", "Unwanted joke."))
        try await waitUntil { rig.chat.calls.contains { $0.system.contains("already on the board") } }
        rig.chat.fulfill(where: { $0.system.contains("already on the board") }, body: "The pawn takes the centre.")
        try await waitUntil { rig.engine.boardVersion == 1 }
        XCTAssertTrue(rig.engine.picture.taunt.isEmpty)
        XCTAssertTrue(rig.engine.referee.accepted[0].taunt.isEmpty)
        XCTAssertFalse(rig.engine.picture.replies.contains { $0.text.contains("Unwanted joke") || $0.text.contains("Rejected joke") })
        XCTAssertFalse(rig.engine.archive.journal.contains { $0.kind == "taunt" })
        XCTAssertTrue(rig.engine.spokenTaunts.isEmpty)
        XCTAssertEqual(draws, 2, "next position gets a new draw")
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    func testMateTauntBypassesLotteryAndPrecedesFinalCommentary() async throws {
        var black = Seat.defaultBlack(apiKey: "k"); black.persona = .gervais
        let rig = try makeRig(blackSeat: black)
        var saved = rig.engine.checkpoint
        for move in ["f2f3", "e7e5", "g2g4"] { _ = saved.referee.submit(rawMove: move, taunt: "") }
        rig.engine.restore(saved)
        rig.engine.tauntDraw = { 99 }
        try await rig.engine.start(at: 0)
        try await waitUntil { rig.chat.calls.count == 1 }
        rig.chat.fulfill(where: { $0.system.contains("You are Black") }, body: jsonMove("d8h4", "Your king forgot the exit."))
        try await waitUntil { rig.chat.calls.contains { $0.user.contains("Result:") } }
        rig.chat.fulfill(where: { $0.user.contains("Result:") }, body: "Black wins by checkmate.")
        try await waitUntil { rig.engine.speech.contains { $0.kind == .final } }
        XCTAssertEqual(rig.engine.spokenTaunts.last?.text, "Your king forgot the exit.")
        XCTAssertEqual(rig.engine.referee.end, .checkmate(winner: .black))
        let voice = try XCTUnwrap(rig.engine.voice as? ScriptedVoice)
        XCTAssertEqual(voice.spoken.map(\.kind), [.taunt, .final])
        rig.engine.stop()
        try await rig.engine.closeArchive()
    }

    private func makeRig(
        whitePlayer: PlayerConfiguration? = nil, blackPlayer: PlayerConfiguration? = nil,
        hostPlayer: PlayerConfiguration? = nil, gameMemory: GameMemory = GameMemory(), whiteSeat: Seat? = nil, blackSeat: Seat? = nil
    ) throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = MatchArchive(directory: directory,
                                   whiteName: whiteSeat?.name ?? whitePlayer?.provider.rawValue ?? "Grok",
                                   blackName: blackPlayer?.provider.rawValue ?? "ChatGPT")
        let chat = ScriptedChat()
        let secret = "CHESSARENA-SECRET-KEY-9f3c2a7b"
        let keys = rigKeys
        let white = whiteSeat ?? whitePlayer?.seat(side: .white, keys: keys) ?? Seat.defaultWhite(apiKey: secret)
        let black = blackSeat ?? blackPlayer?.seat(side: .black, keys: keys) ?? Seat.defaultBlack(apiKey: secret)
        let host = hostPlayer?.seat(side: .white, keys: keys)
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
        engine.tauntDraw = { 0 } // Existing speech-order tests always exercise an allowed taunt.
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

private let rigKeys = ProviderKeys(grok: "grok-key", chatGPT: "openai-key", anthropic: "claude-key", claudeAccess: .apiKey, deepseek: "deepseek-key")

private func expectedKey(_ provider: NeuralProvider) -> String {
    switch provider {
    case .grok: return "grok-key"
    case .chatGPT: return "openai-key"
    case .gemini, .lc0: return ""
    case .claude: return "claude-key"
    case .deepseek: return "deepseek-key"
    }
}

private func jsonMove(_ uci: String, _ taunt: String) -> String {
    let payload: [String: String] = ["move": uci, "taunt": taunt]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    return String(data: data, encoding: .utf8)!
}
