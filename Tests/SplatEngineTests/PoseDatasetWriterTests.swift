import Foundation
import PoseCore
import XCTest
@testable import SplatEngine

final class PoseDatasetWriterTests: XCTestCase {
    func testWritesPoseEstimationAsTrainerDataset() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imagesURL = rootURL.appendingPathComponent("source", isDirectory: true)
        let outputURL = rootURL.appendingPathComponent("dataset", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let transform = try Matrix4x4(rows: [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 1],
            [0, 0, 0, 1],
        ])
        let result = PoseEstimationResult(
            frames: [
                DatasetFrame(
                    imagePath: "images/frame.jpg",
                    intrinsics: CameraIntrinsics(
                        width: 10,
                        height: 10,
                        focalLengthX: 8,
                        focalLengthY: 8,
                        principalPointX: 5,
                        principalPointY: 5
                    ),
                    cameraToWorld: transform
                ),
            ],
            points: [
                PointCloudPoint(
                    position: Vector3(x: 0, y: 0, z: 0),
                    color: RGBColor(red: 0, green: 0, blue: 0)
                ),
            ],
            totalImageCount: 1
        )

        try PoseDatasetWriter.write(
            result,
            imagesURL: imagesURL,
            to: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent("transforms.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent("sparse_pc.ply").path
        ))
    }
}
