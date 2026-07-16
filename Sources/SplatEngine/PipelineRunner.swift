import Foundation

public protocol FrameExtracting: Sendable {
    func extract(
        videoURL: URL,
        outputURL: URL,
        options: FrameExtractionOptions,
        progress: FrameExtractor.ProgressHandler?
    ) async throws -> FrameExtractionResult
}

public protocol PoseEstimating: Sendable {
    @available(macOS 26.0, *)
    func estimate(
        imagesURL: URL,
        options: PoseEstimationOptions,
        meshOutputURL: URL?,
        progress: PoseEstimator.ProgressHandler?
    ) async throws -> PoseEstimationResult
}

extension FrameExtractor: FrameExtracting {}
extension PoseEstimator: PoseEstimating {}

public enum PipelineStage: String, Sendable, Equatable {
    case extractingFrames
    case estimatingPoses
    case buildingPointCloud
    case writingDataset
    case training
    case postprocessing
}

public struct PipelineProgress: Sendable, Equatable {
    public let stage: PipelineStage
    public let fraction: Double
    /// Human-readable line describing exactly what the pipeline is doing
    /// right now (e.g. "msplat step 8,214 / 15,000").
    public let detail: String?

    public init(stage: PipelineStage, fraction: Double, detail: String? = nil) {
        self.stage = stage
        self.fraction = fraction
        self.detail = detail
    }
}

public struct PipelineResult: Sendable, Equatable {
    public let extraction: FrameExtractionResult
    public let poseEstimation: PoseEstimationResult
    public let training: TrainingResult
    public let cleaning: SplatCleaningResult
    public let sceneURL: URL

    public init(
        extraction: FrameExtractionResult,
        poseEstimation: PoseEstimationResult,
        training: TrainingResult,
        cleaning: SplatCleaningResult,
        sceneURL: URL
    ) {
        self.extraction = extraction
        self.poseEstimation = poseEstimation
        self.training = training
        self.cleaning = cleaning
        self.sceneURL = sceneURL
    }
}

public struct PipelineRunner: Sendable {
    public typealias ProgressHandler =
        @Sendable (PipelineProgress) async -> Void

    private let frameExtractor: any FrameExtracting
    private let poseEstimator: any PoseEstimating
    private let trainer: any TrainerBackend
    private let postprocessor: any SplatPostprocessing
    private let frameOptions: FrameExtractionOptions
    private let poseOptions: PoseEstimationOptions
    private let trainingOptions: TrainingOptions

    public init(
        frameExtractor: any FrameExtracting = FrameExtractor(),
        poseEstimator: any PoseEstimating = PoseEstimator(),
        trainer: any TrainerBackend,
        postprocessor: any SplatPostprocessing = NativeSplatPostprocessor(),
        frameOptions: FrameExtractionOptions = FrameExtractionOptions(),
        poseOptions: PoseEstimationOptions = PoseEstimationOptions(),
        trainingOptions: TrainingOptions = TrainingOptions()
    ) {
        self.frameExtractor = frameExtractor
        self.poseEstimator = poseEstimator
        self.trainer = trainer
        self.postprocessor = postprocessor
        self.frameOptions = frameOptions
        self.poseOptions = poseOptions
        self.trainingOptions = trainingOptions
    }

    @available(macOS 26.0, *)
    public func run(
        videoURL: URL,
        workspaceURL: URL,
        progress: ProgressHandler? = nil
    ) async throws -> PipelineResult {
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let framesURL = workspaceURL.appendingPathComponent(
            "frames",
            isDirectory: true
        )
        let datasetURL = workspaceURL.appendingPathComponent(
            "dataset",
            isDirectory: true
        )
        let trainingURL = workspaceURL.appendingPathComponent(
            "training",
            isDirectory: true
        )
        let outputURL = workspaceURL.appendingPathComponent(
            "output",
            isDirectory: true
        )

        await progress?(PipelineProgress(
            stage: .extractingFrames,
            fraction: 0,
            detail: "Scoring frame sharpness with AVFoundation"
        ))
        let extraction = try await frameExtractor.extract(
            videoURL: videoURL,
            outputURL: framesURL,
            options: frameOptions,
            progress: { extractionProgress in
                await progress?(PipelineProgress(
                    stage: .extractingFrames,
                    fraction: extractionProgress.fraction,
                    detail: "Decoding sharpest frame "
                        + "\(extractionProgress.completedFrames) of "
                        + "\(extractionProgress.totalFrames)"
                ))
            }
        )

        // Optional SHARP instant preview from the first extracted frame.
        // Never blocks or fails the main pipeline.
        if let firstFrame = extraction.frameURLs.first {
            let previewURL = outputURL.appendingPathComponent(
                "sharp-preview.ply"
            )
            Task.detached {
                _ = try? await SharpPreviewRunner.runIfAvailable(
                    inputImageURL: firstFrame,
                    outputPLYURL: previewURL
                )
            }
        }

        let meshURL = outputURL.appendingPathComponent("mesh.usdz")
        let poseEstimation = try await poseEstimator.estimate(
            imagesURL: framesURL,
            options: poseOptions,
            meshOutputURL: meshURL,
            progress: { poseProgress in
                let stage: PipelineStage
                let detail: String
                switch poseProgress.stage {
                case .poses:
                    stage = .estimatingPoses
                    detail = "PhotogrammetrySession registering camera poses"
                case .pointCloud:
                    stage = .buildingPointCloud
                    detail = "Fusing sparse point cloud from registered views"
                case .mesh:
                    stage = .buildingPointCloud
                    detail = "Reconstructing preview mesh"
                }
                await progress?(PipelineProgress(
                    stage: stage,
                    fraction: poseProgress.fraction,
                    detail: detail
                ))
            }
        )

        await progress?(PipelineProgress(
            stage: .writingDataset,
            fraction: 0,
            detail: "Writing Nerfstudio dataset "
                + "(\(poseEstimation.frames.count) posed frames)"
        ))
        try PoseDatasetWriter.write(
            poseEstimation,
            imagesURL: framesURL,
            to: datasetURL
        )
        await progress?(PipelineProgress(
            stage: .writingDataset,
            fraction: 1,
            detail: "Dataset ready — transforms.json + sparse points"
        ))

        let totalSteps = trainingOptions.totalSteps
        await progress?(PipelineProgress(
            stage: .training,
            fraction: 0,
            detail: "Starting msplat Metal trainer "
                + "(\(totalSteps.formatted()) steps)"
        ))
        let training = try await trainer.train(
            datasetURL: datasetURL,
            outputURL: trainingURL,
            options: trainingOptions,
            progress: { trainingProgress in
                await progress?(PipelineProgress(
                    stage: .training,
                    fraction: trainingProgress.fraction,
                    detail: "msplat step "
                        + "\(trainingProgress.completedSteps.formatted())"
                        + " of "
                        + "\(trainingProgress.totalSteps.formatted())"
                ))
            }
        )

        await progress?(PipelineProgress(
            stage: .postprocessing,
            fraction: 0,
            detail: "Cleaning \(training.gaussianCount.formatted()) Gaussians"
                + " — floaters, haze, subject isolation"
        ))
        let sceneURL = outputURL.appendingPathComponent("scene-hq.ply")
        let cameraCenters = poseEstimation.frames.map { frame in
            let position = frame.cameraToWorld.cameraPosition
            return SIMD3(
                Float(position.x),
                Float(position.y),
                Float(position.z)
            )
        }
        let cleaning = try await postprocessor.process(
            inputURL: training.plyURL,
            outputURL: sceneURL,
            cameraCenters: cameraCenters
        )
        await progress?(PipelineProgress(
            stage: .postprocessing,
            fraction: 1,
            detail: "Kept \(cleaning.keptCount.formatted()) of "
                + "\(cleaning.totalCount.formatted()) Gaussians"
        ))

        return PipelineResult(
            extraction: extraction,
            poseEstimation: poseEstimation,
            training: training,
            cleaning: cleaning,
            sceneURL: sceneURL
        )
    }
}
