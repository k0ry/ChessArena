import XCTest
import SceneKit
@testable import ChessArenaCore

final class CaptureAnimationTests: XCTestCase {
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
