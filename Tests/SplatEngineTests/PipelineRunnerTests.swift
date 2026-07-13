import Foundation
import PoseCore
import XCTest
@testable import SplatEngine

final class PipelineRunnerTests: XCTestCase {
    @available(macOS 26.0, *)
    func testRunsEveryPipelineStageAndReturnsTrainerExport() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let recorder = PipelineProgressRecorder()
        let runner = PipelineRunner(
            frameExtractor: StubFrameExtractor(),
            poseEstimator: StubPoseEstimator(),
            trainer: StubTrainer(),
            postprocessor: StubSplatPostprocessor()
        )

        let result = try await runner.run(
            videoURL: workspaceURL.appendingPathComponent("source.mov"),
            workspaceURL: workspaceURL,
            progress: { progress in
                await recorder.record(progress)
            }
        )

        XCTAssertEqual(result.training.gaussianCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.training.plyURL.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.sceneURL.path
        ))
        XCTAssertEqual(result.cleaning.keptCount, 1)
        let stages = await recorder.values.map(\.stage)
        XCTAssertTrue(stages.contains(.extractingFrames))
        XCTAssertTrue(stages.contains(.estimatingPoses))
        XCTAssertTrue(stages.contains(.writingDataset))
        XCTAssertTrue(stages.contains(.training))
        XCTAssertTrue(stages.contains(.postprocessing))
    }
}

private struct StubFrameExtractor: FrameExtracting {
    func extract(
        videoURL: URL,
        outputURL: URL,
        options: FrameExtractionOptions,
        progress: FrameExtractor.ProgressHandler?
    ) async throws -> FrameExtractionResult {
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        let frameURL = outputURL.appendingPathComponent("frame_0001.jpg")
        try Data().write(to: frameURL)
        await progress?(FrameExtractionProgress(
            completedFrames: 1,
            totalFrames: 1
        ))
        return FrameExtractionResult(
            frameURLs: [frameURL],
            durationSeconds: 1
        )
    }
}

private struct StubPoseEstimator: PoseEstimating {
    @available(macOS 26.0, *)
    func estimate(
        imagesURL: URL,
        options: PoseEstimationOptions,
        meshOutputURL: URL?,
        progress: PoseEstimator.ProgressHandler?
    ) async throws -> PoseEstimationResult {
        await progress?(PoseEstimationProgress(stage: .poses, fraction: 1))
        let transform = try Matrix4x4(rows: [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 1],
            [0, 0, 0, 1],
        ])
        return PoseEstimationResult(
            frames: [
                DatasetFrame(
                    imagePath: "images/frame_0001.jpg",
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
            totalImageCount: 1,
            meshURL: meshOutputURL
        )
    }
}

private struct StubTrainer: TrainerBackend {
    func train(
        datasetURL: URL,
        outputURL: URL,
        options: TrainingOptions,
        progress: (@Sendable (TrainingProgress) async -> Void)?
    ) async throws -> TrainingResult {
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        let plyURL = outputURL.appendingPathComponent("splat_12000.ply")
        try Data(
            "ply\nformat ascii 1.0\nelement vertex 1\nend_header\n".utf8
        ).write(to: plyURL)
        await progress?(TrainingProgress(
            completedSteps: 12_000,
            totalSteps: 12_000
        ))
        return TrainingResult(
            plyURL: plyURL,
            bytes: 52,
            gaussianCount: 1,
            steps: 12_000
        )
    }
}

private struct StubSplatPostprocessor: SplatPostprocessing {
    func process(
        inputURL: URL,
        outputURL: URL,
        cameraCenters: [SIMD3<Float>]
    ) async throws -> SplatCleaningResult {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cleaned".utf8).write(to: outputURL)
        return SplatCleaningResult(
            center: .zero,
            radius: 1,
            compactRadius: 0.5,
            totalCount: 1,
            keptCount: 1,
            floaterCount: 0,
            hazeRemovedCount: 0,
            subjectIsolatedCount: 0,
            planeFound: false,
            orbitRadius: 2,
            isEnvironment: false,
            cameraPosition: SIMD3(0, 0, 2),
            worldUp: SIMD3(0, 1, 0)
        )
    }
}

private actor PipelineProgressRecorder {
    private(set) var values: [PipelineProgress] = []

    func record(_ progress: PipelineProgress) {
        values.append(progress)
    }
}
