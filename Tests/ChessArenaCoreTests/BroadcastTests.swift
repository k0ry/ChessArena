import AppKit
import AVFoundation
import SceneKit
import XCTest
@testable import ChessArenaCore

final class BroadcastTests: XCTestCase {
    func testChronicleClockPreparesAtFourTwentyAndKeepsLaterMarks() {
        var director = ChronicleDirector()
        XCTAssertTrue(director.advance(to: 259, voiceText: nil).isEmpty)
        XCTAssertEqual(director.advance(to: 260, voiceText: nil), [.prepare(300)])
        let started = director.advance(to: 300, voiceText: "Ten minutes is a lie, this is five.")
        XCTAssertEqual(started, [.startChronicle(300), .startVoice("Ten minutes is a lie, this is five.")])
        XCTAssertEqual(director.nextMark, 600)
        _ = director.advance(to: 305, voiceText: "Ten minutes is a lie, this is five.")
        XCTAssertEqual(director.now, 305)
        XCTAssertEqual(director.nextMark, 600)
        XCTAssertEqual(director.advance(to: 314, voiceText: nil), [.endChronicle])
        XCTAssertEqual(director.advance(to: 600, voiceText: "later"), [.prepare(600), .startChronicle(600), .startVoice("later")])
        XCTAssertEqual(director.nextMark, 900)
    }

    func testChronicleWaitsForASafeCutAndPlaysOnce() {
        var director = ChronicleDirector()
        director.blocked = true
        XCTAssertEqual(director.advance(to: 260, voiceText: nil), [.prepare(300)])
        XCTAssertEqual(director.advance(to: 300, voiceText: "ready"), [])
        director.blocked = false
        XCTAssertEqual(director.advance(to: 305, voiceText: "ready"), [.startChronicle(300), .startVoice("ready")])
        XCTAssertEqual(director.advance(to: 310, voiceText: "ready"), [])
        XCTAssertEqual(director.advance(to: 319, voiceText: nil), [.endChronicle])
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

    func testLateVoiceAndShortGameStillScheduleTheChronicle() {
        var late = ChronicleDirector()
        _ = late.advance(to: 260, voiceText: nil)
        XCTAssertEqual(late.advance(to: 300, voiceText: nil), [.startChronicle(300)])
        XCTAssertEqual(late.advance(to: 302, voiceText: "Two moves and a mood."), [.startVoice("Two moves and a mood.")])

        var early = ChronicleDirector()
        XCTAssertEqual(early.advance(to: 300, voiceText: "Almost nothing happened, proudly."), [.prepare(300), .startChronicle(300), .startVoice("Almost nothing happened, proudly.")])
    }

    func testFinalCardReplacesOrFollowsTheChronicle() {
        var pending = ChronicleDirector()
        pending.gameOver = true
        XCTAssertEqual(pending.advance(to: 120, voiceText: nil), [.startFinal])
        XCTAssertEqual(pending.advance(to: 134, voiceText: nil), [.endFinal])
        XCTAssertTrue(pending.advance(to: 300, voiceText: "nope").isEmpty)

        var playing = ChronicleDirector()
        _ = playing.advance(to: 300, voiceText: "live")
        playing.gameOver = true
        XCTAssertEqual(playing.advance(to: 305, voiceText: "live"), [])
        XCTAssertEqual(playing.advance(to: 314, voiceText: nil), [.endChronicle, .startFinal])
        XCTAssertEqual(playing.advance(to: 328, voiceText: nil), [.endFinal])
        XCTAssertTrue(playing.advance(to: 600, voiceText: "extra").isEmpty)
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
