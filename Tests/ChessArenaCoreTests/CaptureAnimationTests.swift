import XCTest
import SceneKit
@testable import ChessArenaCore

final class CaptureAnimationTests: XCTestCase {
    func testResetBoardClearsCaptureMotionTrailsAndThinkingPulse() throws {
        let board = BoardScene()
        board.orbitCamera(yaw: 0.6, pitch: 0.1)
        let camera = board.cameraCheckpoint
        var before = Position.standard()
        for uci in ["e2e4", "d7d5"] { before = before.applying(try XCTUnwrap(before.parseUCI(uci))) }
        let capture = try XCTUnwrap(before.parseUCI("e4d5"))
        board.show(position: before)
        board.animate(move: capture, positionAfter: before.applying(capture), side: .white, duration: 30)
        board.setThinking(.black)
        let moving = try XCTUnwrap(board.node(named: "piece-pawn-d5"))
        let flying = try XCTUnwrap(board.node(named: "captured-d5"))
        let pulse = try XCTUnwrap(board.node(named: "pulse-black"))
        XCTAssertNotNil(board.node(named: "trail-cold-e4d5"))

        board.resetBoard()

        XCTAssertFalse(board.isAnimating)
        XCTAssertNil(moving.parent)
        XCTAssertFalse(moving.hasActions)
        XCTAssertNil(flying.parent)
        XCTAssertFalse(flying.hasActions)
        XCTAssertTrue(pulse.isHidden)
        XCTAssertFalse(pulse.hasActions)
        XCTAssertNil(board.node(named: "capture-flash"))
        XCTAssertNil(board.node(named: "trail-cold-e4d5"))
        XCTAssertEqual(board.cameraCheckpoint, camera)
        let fresh = BoardScene()
        let pieces = board.scene.rootNode.childNodes.filter { $0.name?.hasPrefix("piece-") == true }
        XCTAssertEqual(pieces.count, 32)
        for node in pieces {
            let expected = try XCTUnwrap(fresh.node(named: try XCTUnwrap(node.name)))
            XCTAssertEqual(node.position.x, expected.position.x)
            XCTAssertEqual(node.position.y, expected.position.y)
            XCTAssertEqual(node.position.z, expected.position.z)
        }
    }

    func testResetAfterFinalChronicleRemovesAllHistoricalTrails() throws {
        let board = BoardScene()
        var position = Position.standard()
        var moves: [ChessMove] = []
        for uci in ["f2f3", "e7e5", "g2g4", "d8h4"] {
            let move = try XCTUnwrap(position.parseUCI(uci))
            moves.append(move)
            position = position.applying(move)
        }
        board.layChronicle(moves: moves, sides: [.white, .black, .white, .black])
        XCTAssertEqual(board.scene.rootNode.childNodes.filter { $0.name?.hasPrefix("trail-") == true }.count, 4)
        board.resetBoard()
        board.resetBoard() // Repeated resets must not duplicate pieces or stage nodes.
        XCTAssertFalse(board.scene.rootNode.childNodes.contains { $0.name?.hasPrefix("trail-") == true })
        XCTAssertNotNil(board.node(named: "piece-queen-d8"))
        XCTAssertNil(board.node(named: "piece-queen-h4"))
        XCTAssertEqual(board.scene.rootNode.childNodes.filter { $0.name?.hasPrefix("piece-") == true }.count, 32)
    }

    func testCaptureCopyFliesOutsideBoardAndFades() {
        for x: Float in [-3.5, 0.5, 3.5] {
            let flight = CaptureFlight(start: SCNVector3(x, 0.5, -0.5))
            let start = flight.pose(at: 0), middle = flight.pose(at: 0.5), end = flight.pose(at: 1)
            XCTAssertEqual(start.position.x, CGFloat(x), accuracy: 0.001)
            XCTAssertEqual(start.opacity, 1)
            XCTAssertGreaterThan(middle.position.y, 3)
            XCTAssertGreaterThan(abs(end.position.x), 4.4)
            XCTAssertEqual(end.opacity, 0)
            XCTAssertGreaterThan(abs(middle.rotation.y), 1)
        }
    }

    func testNormalAndEnPassantCapturesKeepOnlyLegalPiecesAndCleanEffects() throws {
        for moves in [["e2e4", "d7d5", "e4d5"], ["e2e4", "a7a6", "e4e5", "d7d5", "e5d6"]] {
            let board = BoardScene()
            var position = Position.standard()
            for uci in moves.dropLast() { position = position.applying(try XCTUnwrap(position.parseUCI(uci))) }
            board.show(position: position)
            let move = try XCTUnwrap(position.parseUCI(moves.last!))
            let after = position.applying(move)
            board.animate(move: move, positionAfter: after, side: .white, duration: 1.2)
            XCTAssertEqual(board.scene.rootNode.childNodes.filter { $0.name?.hasPrefix("piece-") == true }.count, 31)
            XCTAssertNotNil(board.node(named: "captured-d5"))
            XCTAssertNotNil(board.node(named: "piece-pawn-" + move.to.uci))
            XCTAssertTrue(board.isAnimating)
            board.finishAnimation()
            XCTAssertNil(board.node(named: "captured-d5"))
            XCTAssertFalse(board.isAnimating)
            board.show(position: position)
            board.animate(move: move, positionAfter: after, side: .white, duration: 1.2)
            board.show(position: .standard())
            XCTAssertNil(board.node(named: "captured-d5"))
            XCTAssertEqual(board.scene.rootNode.childNodes.filter { $0.name?.hasPrefix("piece-") == true }.count, 32)
        }
    }
}
