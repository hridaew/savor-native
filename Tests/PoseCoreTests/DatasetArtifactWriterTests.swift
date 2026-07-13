import Foundation
import XCTest
@testable import PoseCore

final class DatasetArtifactWriterTests: XCTestCase {
    func testDoesNotWriteArtifactsWhenPoseSanityFails() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let transform = try Matrix4x4(rows: [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 1],
            [0, 0, 0, 1],
        ])
        let frame = DatasetFrame(
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
        )

        XCTAssertThrowsError(
            try DatasetArtifactWriter.write(
                frames: [frame],
                totalImageCount: 1,
                points: [],
                to: outputURL
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputURL.appending(path: "transforms.json").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputURL.appending(path: "sparse_pc.ply").path
            )
        )
    }

    func testSecondArtifactWriteFailureLeavesNoVisibleDataset() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let imagesURL = rootURL.appending(path: "source", directoryHint: .isDirectory)
        let outputURL = rootURL.appending(path: "dataset", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: imagesURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let transform = try Matrix4x4(rows: [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 1],
            [0, 0, 0, 1],
        ])
        let frame = DatasetFrame(
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
        )
        let point = PointCloudPoint(
            position: Vector3(x: 0, y: 0, z: 0),
            color: RGBColor(red: 0, green: 0, blue: 0)
        )
        var writeCount = 0

        XCTAssertThrowsError(
            try DatasetArtifactWriter.write(
                frames: [frame],
                totalImageCount: 1,
                points: [point],
                imagesURL: imagesURL,
                to: outputURL,
                fileManager: .default,
                dataWriter: { data, url in
                    writeCount += 1
                    if writeCount == 2 {
                        throw TestError.secondWrite
                    }
                    try data.write(to: url, options: .atomic)
                }
            )
        )
        XCTAssertEqual(writeCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testCommitsCompleteDatasetDirectory() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let imagesURL = rootURL.appending(path: "source", directoryHint: .isDirectory)
        let outputURL = rootURL.appending(path: "dataset", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: imagesURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let transform = try Matrix4x4(rows: [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 1],
            [0, 0, 0, 1],
        ])
        let frame = DatasetFrame(
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
        )
        let point = PointCloudPoint(
            position: Vector3(x: 0, y: 0, z: 0),
            color: RGBColor(red: 0, green: 0, blue: 0)
        )

        try DatasetArtifactWriter.write(
            frames: [frame],
            totalImageCount: 1,
            points: [point],
            imagesURL: imagesURL,
            to: outputURL
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputURL.appending(path: "transforms.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputURL.appending(path: "sparse_pc.ply").path
            )
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: outputURL.appending(path: "images").path
            ),
            imagesURL.path
        )
    }

    private enum TestError: Swift.Error {
        case secondWrite
    }
}
