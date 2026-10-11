import SceneKit
import XCTest
@testable import ChessArenaCore

final class CameraTests: XCTestCase {
    func testManualOrbitSurvivesTickerAndNewPosition() {
        let board = BoardScene()
        let original = board.cameraNode.position
        board.orbitCamera(yaw: 0.7, pitch: 0.1)
        let rotated = board.cameraNode.position
        XCTAssertTrue(board.isCameraManual)
        XCTAssertNotEqual(rotated.x, original.x)
        board.applyCamera(at: 300)
        board.show(position: .standard())
        XCTAssertEqual(board.cameraNode.position.x, rotated.x)
        XCTAssertEqual(board.cameraNode.position.y, rotated.y)
        XCTAssertEqual(board.cameraNode.position.z, rotated.z)
    }

    func testZoomIsBoundedAndResetRestoresAutomaticCamera() {
        let board = BoardScene()
        board.zoomCamera(scale: 2)
        XCTAssertGreaterThan(distance(board), 18)
        board.zoomCamera(scale: 1000)
        XCTAssertEqual(distance(board), 45, accuracy: 0.001)
        board.zoomCamera(scale: 0.0001)
        XCTAssertEqual(distance(board), 9, accuracy: 0.001)
        board.orbitCamera(yaw: 0, pitch: -100)
        XCTAssertGreaterThan(board.cameraNode.position.y, 0)
        board.resetCamera()
        XCTAssertFalse(board.isCameraManual)
        XCTAssertEqual(board.cameraNode.position.x, board.cameraPosition(at: 0).x)
        board.applyCamera(at: 50)
        XCTAssertEqual(board.cameraNode.position.x, board.cameraPosition(at: 50).x)
    }

    private func distance(_ board: BoardScene) -> Float {
        let p = board.cameraNode.position
        return Float(sqrt(p.x * p.x + p.y * p.y + p.z * p.z))
    }
}
