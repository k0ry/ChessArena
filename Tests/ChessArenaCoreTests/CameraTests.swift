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

    func testZoomIsBoundedAndResetKeepsBoardEdgeHorizontal() {
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
        XCTAssertTrue(board.isCameraManual)
        XCTAssertEqual(board.cameraNode.position.x, 0, accuracy: 0.001)
        let reset = board.cameraCheckpoint
        XCTAssertEqual(board.cameraProjection(of: SIMD3(1, 0, 0)).y, 0, accuracy: 0.0001)
        board.applyCamera(at: 50)
        XCTAssertEqual(board.cameraCheckpoint, reset)
        XCTAssertEqual(board.cameraNode.position.x, 0, accuracy: 0.001)
    }

    func testSelectedAxisRestrictsDragAndTrackpadRotation() {
        for axis in CameraRotationAxis.allCases {
            let board = BoardScene()
            board.resetCamera()
            board.selectCameraAxis(axis)
            let initial = board.cameraCheckpoint
            board.orbitCamera(yaw: 0.3, pitch: 0.2)
            board.rotateCamera(by: 0.1)
            let changed = board.cameraCheckpoint
            XCTAssertEqual(changed.yaw, initial.yaw + (axis == .y ? 0.4 : 0), accuracy: 0.0001)
            XCTAssertEqual(changed.pitch, initial.pitch + (axis == .x ? 0.3 : 0), accuracy: 0.0001)
            XCTAssertEqual(changed.roll ?? 0, axis == .z ? 0.4 : 0, accuracy: 0.0001)
            board.zoomCamera(scale: 1.2)
            XCTAssertEqual(board.cameraCheckpoint.yaw, changed.yaw)
            XCTAssertEqual(board.cameraCheckpoint.pitch, changed.pitch)
            XCTAssertEqual(board.cameraCheckpoint.roll, changed.roll)
            board.selectCameraAxis(nil)
            board.orbitCamera(yaw: 0.1, pitch: 0.1)
            XCTAssertNotEqual(board.cameraCheckpoint.yaw, changed.yaw)
            XCTAssertNotEqual(board.cameraCheckpoint.pitch, changed.pitch)
        }
    }

    func testRollAndAxisRestoreAndResetClearsBoth() throws {
        let board = BoardScene()
        board.resetCamera()
        board.selectCameraAxis(.z)
        board.rotateCamera(by: 0.4)
        XCTAssertNotEqual(board.cameraProjection(of: SIMD3(1, 0, 0)).y, 0)
        let encoded = try JSONEncoder().encode(board.cameraCheckpoint)
        let restored = BoardScene()
        restored.restoreCamera(try JSONDecoder().decode(CameraCheckpoint.self, from: encoded))
        XCTAssertEqual(restored.cameraCheckpoint, board.cameraCheckpoint)
        XCTAssertEqual(restored.cameraProjection(of: SIMD3(1, 0, 0)).y,
                       board.cameraProjection(of: SIMD3(1, 0, 0)).y, accuracy: 0.0001)
        restored.resetCamera()
        XCTAssertNil(restored.selectedCameraAxis)
        XCTAssertEqual(restored.cameraCheckpoint.roll, 0)
        XCTAssertEqual(restored.cameraProjection(of: SIMD3(1, 0, 0)).y, 0, accuracy: 0.0001)
        let legacy = Data(#"{"manual":true,"yaw":0,"pitch":0.7,"distance":18}"#.utf8)
        restored.restoreCamera(try JSONDecoder().decode(CameraCheckpoint.self, from: legacy))
        XCTAssertNil(restored.selectedCameraAxis)
        XCTAssertEqual(restored.cameraCheckpoint.roll, 0)
    }

    private func distance(_ board: BoardScene) -> Float {
        let p = board.cameraNode.position
        return Float(sqrt(p.x * p.x + p.y * p.y + p.z * p.z))
    }
}
