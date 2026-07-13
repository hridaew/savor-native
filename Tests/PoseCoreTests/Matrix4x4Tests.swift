import XCTest
import simd
@testable import PoseCore

final class Matrix4x4Tests: XCTestCase {
    func testRejectsRowsThatAreNotFourByFour() {
        XCTAssertThrowsError(try Matrix4x4(rows: [[1.0]])) { error in
            XCTAssertEqual(error as? Matrix4x4.Error, .invalidShape)
        }
    }

    func testCameraPositionComesFromTranslationColumn() throws {
        let matrix = try Matrix4x4(rows: [
            [1, 0, 0, 2.5],
            [0, 1, 0, -1.25],
            [0, 0, 1, 4.0],
            [0, 0, 0, 1],
        ])

        XCTAssertEqual(matrix.cameraPosition, Vector3(x: 2.5, y: -1.25, z: 4.0))
    }

    func testOpenGLCameraForwardIsNegativeZColumn() throws {
        let matrix = try Matrix4x4(rows: [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1],
        ])

        XCTAssertEqual(matrix.openGLForward, Vector3(x: 0, y: 0, z: -1))
    }

    func testBuildsCameraToWorldFromPoseTranslationAndRotation() {
        let rotation = simd_quatf(
            angle: .pi / 2,
            axis: SIMD3<Float>(0, 1, 0)
        )

        let matrix = Matrix4x4(
            cameraTranslation: SIMD3<Float>(2, 3, 4),
            rotation: rotation
        )

        XCTAssertEqual(matrix.cameraPosition, Vector3(x: 2, y: 3, z: 4))
        XCTAssertEqual(matrix.openGLForward.x, -1, accuracy: 0.000_001)
        XCTAssertEqual(matrix.openGLForward.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(matrix.openGLForward.z, 0, accuracy: 0.000_001)
    }
}
