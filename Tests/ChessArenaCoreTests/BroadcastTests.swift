import AppKit
import AVFoundation
import SceneKit
import XCTest
@testable import ChessArenaCore

final class BroadcastTests: XCTestCase {
    func testSpokenTextRemovesEscapesWithoutSpeakingBackslashes() {
        XCTAssertEqual(SpokenText.clean(#"План хорош.\nКороль не согласен.\tСовсем."#), "План хорош. Король не согласен. Совсем.")
        XCTAssertEqual(SpokenText.clean(#"План \"надёжный\".\\nОчень."#), "План \"надёжный\". Очень.")
        XCTAssertEqual(SpokenText.clean(#""План.\nДиагноз ясен.""#), "План. Диагноз ясен.")
        XCTAssertEqual(SpokenText.clean(#"\u041c\u0430\u0442.\nКонсилиум окончен."#), "Мат. Консилиум окончен.")
        XCTAssertEqual(SpokenText.clean("План \\ сомнительный."), "План сомнительный.")
        XCTAssertEqual(SpokenText.clean("Qh4# — диагноз. 1/2, а не победа!"), "Qh4# — диагноз. 1/2, а не победа!")
        XCTAssertEqual(SpokenText.clean(#"\n\t\\"#), "")
    }

    func testLiveGameNeverSchedulesPeriodicRecaps() {
        var director = ChronicleDirector()
        for time in [259.0, 260, 300, 314, 560, 600, 900, 3600, 86400] {
            XCTAssertTrue(director.advance(to: time).isEmpty)
            XCTAssertEqual(director.phase, .live)
            XCTAssertEqual(director.now, time)
        }
    }

    @MainActor
    func testSynthesizerReceivesNoBackslashNamesOrUnicodeVariants() throws {
        for artifact in ["backslash", "BACKSLASH", "back slash", "back-slash", "backslashes",
                         "бэк слеш", "бэкслэш", "бекслеш", "＼", "﹨", "∖", "⧵", "⧹",
                         "&bsol;", "&#92;", "&#x5C;", #"\u005c"#] {
            let utterance = try XCTUnwrap(SystemVoice.makeUtterance("Ход. \(artifact) План?", language: .russian))
            XCTAssertEqual(utterance.speechString, "Ход. План?", artifact)
            XCTAssertNil(SystemVoice.makeUtterance(artifact, language: .russian), artifact)
            XCTAssertEqual(SpokenText.clean(utterance.speechString), utterance.speechString)
        }
        XCTAssertEqual(SpokenText.clean("И снова backslash, король под ударом."), "И снова, король под ударом.")
        XCTAssertEqual(SpokenText.clean("backslashCounter — имя; 1/2 — счёт."), "backslashCounter — имя; 1/2 — счёт.")
    }

    func testReplayRunsFromTheFirstMoveWithSideTints() {
        let sides: [Side] = [.white, .black, .white, .black, .white, .black]
        let steps = ReplayPlan.steps(sides: sides)
        XCTAssertEqual(steps.first?.ply, 0)
        XCTAssertEqual(steps.last?.ply, 6)
        XCTAssertEqual(steps.filter { $0.tint == "cold" }.count, 3)
        XCTAssertEqual(steps.filter { $0.tint == "amber" }.count, 3)
        let prompt = Prompts.chronicle(moves: ["e4", "e5"], previous: ["The knight pays rent."])
        XCTAssertTrue(prompt.user.contains("The knight pays rent."))
        XCTAssertTrue(prompt.user.contains("e4"))
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        XCTAssertEqual(limitWords(long).split(separator: " ").count, 45)
    }

    func testFinalCardStartsOnlyAfterGameOverAndPlaysOnce() {
        for endTime in [120.0, 300, 605] {
            var director = ChronicleDirector()
            XCTAssertTrue(director.advance(to: endTime).isEmpty)
            director.gameOver = true
            XCTAssertEqual(director.advance(to: endTime), [.startFinal])
            XCTAssertTrue(director.advance(to: endTime + 29).isEmpty)
            XCTAssertEqual(director.advance(to: endTime + 30), [.endFinal])
            XCTAssertEqual(director.phase, .done)
            XCTAssertTrue(director.advance(to: endTime + 300).isEmpty)
        }
    }

    func testSceneShowsDistinctPiecesAndMoveTrail() throws {
        let board = BoardScene()
        let kinds = ["pawn", "knight", "bishop", "rook", "queen", "king"]
        for kind in kinds {
            XCTAssertNotNil(board.node(named: "piece-\(kind)-a2") ?? board.node(named: "piece-\(kind)-a1") ?? board.node(named: "piece-\(kind)-b1") ?? firstNode(board, prefix: "piece-\(kind)-"))
        }
        let white = board.node(named: "piece-pawn-e2")
        let black = board.node(named: "piece-pawn-e7")
        let whiteColor = color(of: white)
        let blackColor = color(of: black)
        XCTAssertGreaterThan(whiteColor.blueComponent, whiteColor.redComponent)
        XCTAssertGreaterThan(blackColor.redComponent, blackColor.blueComponent)

        board.setThinking(.white)
        XCTAssertEqual(board.node(named: "pulse-white")?.isHidden, false)
        XCTAssertNotNil(board.node(named: "board"))
        let first = board.cameraPosition(at: 0)
        let second = board.cameraPosition(at: 1)
        XCTAssertFalse(first.x == second.x && first.y == second.y && first.z == second.z)

        let move = Position.standard().parseUCI("e2e4")!
        let after = Position.standard().applying(move)
        board.animate(move: move, positionAfter: after, side: .white, duration: 0)
        XCTAssertNil(board.node(named: "piece-pawn-e2"))
        XCTAssertNotNil(board.node(named: "piece-pawn-e4"))
        XCTAssertNotNil(board.node(named: "trail-cold-e2e4"))
        XCTAssertFalse(board.isAnimating)

        board.cameraNode.position = SCNVector3(0, 16, 0.2)
        board.cameraNode.look(at: SCNVector3(0, 0, 0))
        let image = try XCTUnwrap(board.renderFrame())
        XCTAssertEqual(image.size.width, CGFloat(StageMetrics.width), accuracy: 1)
        XCTAssertEqual(image.size.height, CGFloat(StageMetrics.height), accuracy: 1)
        let pixels = try XCTUnwrap(board.renderedBGRA(width: StageMetrics.width, height: StageMetrics.height))
        XCTAssertTrue(frameContainsColdAndAmber(pixels), "rendered frame is missing a cold or amber piece \(pixelSummary(pixels))")
    }

    func testProgramPictureOmitsSecretsAndControls() throws {
        let secret = "CHESSARENA-SECRET-KEY-9f3c2a7b"
        let picture = BroadcastPicture(
            whiteName: "Grok",
            blackName: "ChatGPT",
            clockText: "00:04",
            line: "The knight arrived nowhere.",
            taunt: "After you.",
            banner: nil
        )
        XCTAssertFalse(picture.broadcastText.contains(secret))
        XCTAssertEqual(StageMetrics.width, 1920)
        XCTAssertEqual(StageMetrics.height, 1080)
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/ChessArena/ProgramView.swift"))
        XCTAssertFalse(source.contains("SecureField"))
        XCTAssertFalse(source.contains("apiKey"))
        XCTAssertTrue(source.contains("StageMetrics.width"))
        XCTAssertTrue(source.contains("StageMetrics.height"))
        let control = try String(contentsOf: packageRoot().appendingPathComponent("Sources/ChessArena/ControlView.swift"))
        XCTAssertTrue(control.contains("SecureField"))
        XCTAssertTrue(control.contains("Проверка тона"))
    }

    private func firstNode(_ board: BoardScene, prefix: String) -> SCNNode? {
        board.scene.rootNode.childNodes(passingTest: { node, _ in
            node.name?.hasPrefix(prefix) == true
        }).first
    }

    private func color(of node: SCNNode?) -> NSColor {
        let material = node?.geometry?.firstMaterial
        return (material?.diffuse.contents as? NSColor) ?? .clear
    }

    private func frameContainsColdAndAmber(_ pixels: [UInt8]) -> Bool {
        var cold = false
        var amber = false
        var index = 0
        while index + 3 < pixels.count {
            let blue = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let red = Int(pixels[index + 2])
            if blue > 180 && blue > red + 30 {
                cold = true
            }
            if red > 180 && green > 70 && blue < 110 {
                amber = true
            }
            if cold && amber { return true }
            index += 16
        }
        return false
    }

    private func pixelSummary(_ pixels: [UInt8]) -> String {
        var maxRed: UInt8 = 0
        var maxGreen: UInt8 = 0
        var maxBlue: UInt8 = 0
        var bright = 0
        var index = 0
        while index + 3 < pixels.count {
            maxBlue = max(maxBlue, pixels[index])
            maxGreen = max(maxGreen, pixels[index + 1])
            maxRed = max(maxRed, pixels[index + 2])
            if pixels[index] > 40 || pixels[index + 1] > 40 || pixels[index + 2] > 40 {
                bright += 1
            }
            index += 16
        }
        return "maxRGB=\(maxRed),\(maxGreen),\(maxBlue) bright=\(bright)"
    }
}

final class ArchiveTests: XCTestCase {
    func testVideoSidecarsAndSecretAbsence() async throws {
        let secret = "CHESSARENA-SECRET-KEY-9f3c2a7b"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = MatchArchive(directory: directory, whiteName: "Grok", blackName: "ChatGPT")
        try archive.open()
        archive.append(pixelBuffer: FrameBuffer.make())
        archive.append(pixelBuffer: FrameBuffer.make(fill: 30))
        let move = AcceptedMove(
            move: Position.standard().parseUCI("e2e4")!,
            san: "e4",
            taunt: "After you.",
            fenAfter: "fen"
        )
        archive.record(move: move, clock: 3)
        archive.record(line: SpokenLine(kind: .move, text: "Ambitious, and slightly lost.", boardVersion: 1, clock: 4))
        archive.appendAudio(samplesForTest())
        try await archive.finish(end: nil)

        let asset = AVURLAsset(url: archive.videoURL)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let size = try await video[0].load(.naturalSize)
        XCTAssertEqual(size.width, 1920, accuracy: 1)
        XCTAssertEqual(size.height, 1080, accuracy: 1)
        XCTAssertFalse(audio.isEmpty)
        let pgn = try String(contentsOf: archive.pgnURL)
        XCTAssertTrue(pgn.contains("1. e4 {After you.}"))
        XCTAssertFalse(pgn.contains("e2e5"))
        let journal = try String(contentsOf: archive.journalURL)
        XCTAssertTrue(journal.contains("Ambitious, and slightly lost."))
        XCTAssertTrue(journal.contains("After you."))
        XCTAssertTrue(journal.contains("3"))
        let videoData = try Data(contentsOf: archive.videoURL)
        let secretData = Data(secret.utf8)
        XCTAssertFalse(videoData.contains(secretData))
        XCTAssertFalse(Data(pgn.utf8).contains(secretData))
        XCTAssertFalse(Data(journal.utf8).contains(secretData))
    }

    private func samplesForTest() -> [Int16] {
        Array(repeating: 1000, count: 4410)
    }
}

private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
