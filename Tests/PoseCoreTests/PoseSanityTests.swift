import XCTest
@testable import PoseCore

final class PoseSanityTests: XCTestCase {
    func testRejectsRegistrationBelowMinimumCoverage() throws {
        let transform = try Matrix4x4(rows: [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 2],
            [0, 0, 0, 1],
        ])
        let frame = PoseFrame(imageName: "frame_00001.jpg", cameraToWorld: transform)

        XCTAssertThrowsError(
            try PoseSanity.validate(
                frames: [frame],
                totalImageCount: 3,
                points: [Vector3(x: 0, y: 0, z: 0)]
            )
        ) { error in
            XCTAssertEqual(
                error as? PoseSanity.Error,
                .insufficientCoverage(actual: 1.0 / 3.0, minimum: 0.5)
            )
        }
    }

    func testRejectsCamerasFacingAwayFromPointCloudCentroid() throws {
        let transform = try Matrix4x4(rows: [
            [-1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, -1, 2],
            [0, 0, 0, 1],
        ])
        let frame = PoseFrame(imageName: "frame_00001.jpg", cameraToWorld: transform)

        XCTAssertThrowsError(
            try PoseSanity.validate(
                frames: [frame],
                totalImageCount: 1,
                points: [Vector3(x: 0, y: 0, z: 0)]
            )
        ) { error in
            XCTAssertEqual(
                error as? PoseSanity.Error,
                .camerasNotFacingPointCloud(actual: 0, minimum: 0.9)
            )
        }
    }

    func testRejectsCameraPathsWithExtremeRadiusOutliers() throws {
        let frames = try [
            makeInwardFrame(name: "a.jpg", z: 1),
            makeInwardFrame(name: "b.jpg", z: 1),
            makeInwardFrame(name: "c.jpg", z: 100),
        ]

        XCTAssertThrowsError(
            try PoseSanity.validate(
                frames: frames,
                totalImageCount: 3,
                points: [Vector3(x: 0, y: 0, z: 0)]
            )
        ) { error in
            XCTAssertEqual(
                error as? PoseSanity.Error,
                .cameraPathNotRingLike(actual: 2.0 / 3.0, minimum: 0.9)
            )
        }
    }

    func testRejectsAnEmptyPointCloud() throws {
        let frame = try makeInwardFrame(name: "frame.jpg", z: 1)

        XCTAssertThrowsError(
            try PoseSanity.validate(
                frames: [frame],
                totalImageCount: 1,
                points: []
            )
        ) { error in
            XCTAssertEqual(error as? PoseSanity.Error, .emptyPointCloud)
        }
    }

    private func makeInwardFrame(name: String, z: Double) throws -> PoseFrame {
        let transform = try Matrix4x4(rows: [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, z],
            [0, 0, 0, 1],
        ])
        return PoseFrame(imageName: name, cameraToWorld: transform)
    }
}
