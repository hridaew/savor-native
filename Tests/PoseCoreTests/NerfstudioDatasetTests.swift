import Foundation
import XCTest
import simd
@testable import PoseCore

final class NerfstudioDatasetTests: XCTestCase {
    func testEncodesPerFrameIntrinsicsAndCameraToWorldTransform() throws {
        let transform = try Matrix4x4(rows: [
            [1, 0, 0, 2],
            [0, 1, 0, 3],
            [0, 0, 1, 4],
            [0, 0, 0, 1],
        ])
        let frame = DatasetFrame(
            imagePath: "images/frame_00001.jpg",
            intrinsics: CameraIntrinsics(
                width: 1920,
                height: 1080,
                focalLengthX: 1200,
                focalLengthY: 1195,
                principalPointX: 960,
                principalPointY: 540
            ),
            cameraToWorld: transform
        )

        let data = try NerfstudioDatasetEncoder.encode(
            frames: [frame],
            pointCloudPath: "sparse_pc.ply"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["camera_model"] as? String, "OPENCV")
        XCTAssertEqual(json["ply_file_path"] as? String, "sparse_pc.ply")

        let frames = try XCTUnwrap(json["frames"] as? [[String: Any]])
        let encoded = try XCTUnwrap(frames.first)
        XCTAssertEqual(encoded["file_path"] as? String, "images/frame_00001.jpg")
        XCTAssertEqual(encoded["w"] as? Int, 1920)
        XCTAssertEqual(encoded["h"] as? Int, 1080)
        XCTAssertEqual(encoded["fl_x"] as? Double, 1200)
        XCTAssertEqual(encoded["fl_y"] as? Double, 1195)
        XCTAssertEqual(encoded["cx"] as? Double, 960)
        XCTAssertEqual(encoded["cy"] as? Double, 540)
        XCTAssertEqual(
            encoded["transform_matrix"] as? [[Double]],
            transform.rows
        )
    }

    func testReadsPhotogrammetryIntrinsicsUsingSIMDColumnLayout() {
        let matrix = simd_float3x3(columns: (
            SIMD3<Float>(1200, 0, 0),
            SIMD3<Float>(0, 1195, 0),
            SIMD3<Float>(960, 540, 1)
        ))

        let intrinsics = CameraIntrinsics(
            matrix: matrix,
            imageWidth: 1920,
            imageHeight: 1080
        )

        XCTAssertEqual(intrinsics.width, 1920)
        XCTAssertEqual(intrinsics.height, 1080)
        XCTAssertEqual(intrinsics.focalLengthX, 1200)
        XCTAssertEqual(intrinsics.focalLengthY, 1195)
        XCTAssertEqual(intrinsics.principalPointX, 960)
        XCTAssertEqual(intrinsics.principalPointY, 540)
    }
}
