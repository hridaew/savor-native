import Foundation
import ImageIO
import PoseCore
import RealityKit

public struct PoseEstimationOptions: Sendable, Equatable {
    public let useSequentialOrdering: Bool
    public let useHighFeatureSensitivity: Bool
    public let isObjectMaskingEnabled: Bool

    public init(
        useSequentialOrdering: Bool = true,
        useHighFeatureSensitivity: Bool = true,
        isObjectMaskingEnabled: Bool = false
    ) {
        self.useSequentialOrdering = useSequentialOrdering
        self.useHighFeatureSensitivity = useHighFeatureSensitivity
        self.isObjectMaskingEnabled = isObjectMaskingEnabled
    }
}

public struct PoseEstimationProgress: Sendable, Equatable {
    public enum Stage: String, Sendable {
        case poses
        case pointCloud
        case mesh
    }

    public let stage: Stage
    public let fraction: Double

    public init(stage: Stage, fraction: Double) {
        self.stage = stage
        self.fraction = fraction
    }
}

public struct PoseEstimator: Sendable {
    public typealias ProgressHandler = @Sendable (PoseEstimationProgress) async -> Void

    public enum Error: Swift.Error {
        case photogrammetryUnsupported
        case noImages(URL)
        case requestFailed(
            request: PhotogrammetrySession.Request,
            underlying: Swift.Error
        )
        case missingPoses
        case missingPointCloud
        case missingIntrinsics(Int)
        case cannotReadImage(URL)
    }

    public init() {}

    @available(macOS 26.0, *)
    public func estimate(
        imagesURL: URL,
        options: PoseEstimationOptions = PoseEstimationOptions(),
        meshOutputURL: URL? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> PoseEstimationResult {
        guard PhotogrammetrySession.isSupported else {
            throw Error.photogrammetryUnsupported
        }
        let imageURLs = try ImageDirectoryScanner.imageURLs(in: imagesURL)
        guard !imageURLs.isEmpty else {
            throw Error.noImages(imagesURL)
        }

        var configuration = PhotogrammetrySession.Configuration()
        configuration.isObjectMaskingEnabled = options.isObjectMaskingEnabled
        if options.useSequentialOrdering {
            configuration.sampleOrdering = .sequential
        }
        if options.useHighFeatureSensitivity {
            configuration.featureSensitivity = .high
        }
        let session = try PhotogrammetrySession(
            input: imagesURL,
            configuration: configuration
        )

        var requests: [PhotogrammetrySession.Request] = [
            .poses,
            .pointCloud,
        ]
        if let meshOutputURL {
            try FileManager.default.createDirectory(
                at: meshOutputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            requests.append(
                .modelFile(url: meshOutputURL, detail: .preview)
            )
        }

        var poses: PhotogrammetrySession.Poses?
        var pointCloud: PhotogrammetrySession.PointCloud?
        var meshURL: URL?
        do {
            try session.process(requests: requests)
            outputLoop: for try await output in session.outputs {
                try Task.checkCancellation()
                switch output {
                case let .requestProgress(request, fractionComplete):
                    switch request {
                    case .poses:
                        await progress?(PoseEstimationProgress(
                            stage: .poses,
                            fraction: fractionComplete
                        ))
                    case .pointCloud:
                        await progress?(PoseEstimationProgress(
                            stage: .pointCloud,
                            fraction: fractionComplete
                        ))
                    case .modelFile:
                        await progress?(PoseEstimationProgress(
                            stage: .mesh,
                            fraction: fractionComplete
                        ))
                    default:
                        break
                    }
                case let .requestComplete(_, result):
                    switch result {
                    case let .poses(value):
                        poses = value
                    case let .pointCloud(value):
                        pointCloud = value
                    case let .modelFile(url):
                        meshURL = url
                    default:
                        break
                    }
                case let .requestError(request, error):
                    // Mesh is best-effort demo polish; poses/point cloud remain required.
                    if case .modelFile = request {
                        continue
                    }
                    throw Error.requestFailed(
                        request: request,
                        underlying: error
                    )
                case .processingComplete:
                    break outputLoop
                case .processingCancelled:
                    throw CancellationError()
                default:
                    break
                }
            }
        } catch is CancellationError {
            session.cancel()
            throw CancellationError()
        }

        guard let poses else {
            throw Error.missingPoses
        }
        guard let pointCloud else {
            throw Error.missingPointCloud
        }
        let resolvedMesh: URL?
        if let meshOutputURL,
           FileManager.default.fileExists(atPath: meshOutputURL.path) {
            resolvedMesh = meshOutputURL
        } else {
            resolvedMesh = meshURL
        }
        return PoseEstimationResult(
            frames: try makeDatasetFrames(poses: poses),
            points: pointCloud.points.map(Self.makePoint),
            totalImageCount: imageURLs.count,
            meshURL: resolvedMesh
        )
    }

    @available(macOS 26.0, *)
    private func makeDatasetFrames(
        poses: PhotogrammetrySession.Poses
    ) throws -> [DatasetFrame] {
        let orderedPoses = poses.posesBySample.sorted { $0.key < $1.key }
        let imageURLs = try SampleImageResolver.orderedURLs(
            forSampleIDs: orderedPoses.map(\.key),
            urlsBySample: poses.urlsBySample
        )
        return try zip(orderedPoses, imageURLs).map { poseEntry, imageURL in
            let (sampleIndex, pose) = poseEntry
            guard let intrinsics = pose.intrinsics else {
                throw Error.missingIntrinsics(sampleIndex)
            }
            let (width, height) = try imageDimensions(at: imageURL)
            return DatasetFrame(
                imagePath: "images/\(imageURL.lastPathComponent)",
                intrinsics: CameraIntrinsics(
                    matrix: intrinsics,
                    imageWidth: width,
                    imageHeight: height
                ),
                cameraToWorld: Matrix4x4(
                    cameraTranslation: pose.translation,
                    rotation: pose.rotation
                )
            )
        }
    }

    private func imageDimensions(at url: URL) throws -> (Int, Int) {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw Error.cannotReadImage(url)
        }
        return (width.intValue, height.intValue)
    }

    private static func makePoint(
        _ point: PhotogrammetrySession.PointCloud.Point
    ) -> PointCloudPoint {
        PointCloudPoint(
            position: Vector3(
                x: Double(point.position.x),
                y: Double(point.position.y),
                z: Double(point.position.z)
            ),
            color: RGBColor(
                red: point.color.x,
                green: point.color.y,
                blue: point.color.z
            )
        )
    }
}

extension PoseEstimator.Error: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .photogrammetryUnsupported:
            "PhotogrammetrySession is not supported on this Mac."
        case let .noImages(url):
            "No supported images found in \(url.path)."
        case let .requestFailed(request, underlying):
            "\(request) request failed: \(underlying)"
        case .missingPoses:
            "PhotogrammetrySession completed without a Poses payload."
        case .missingPointCloud:
            "PhotogrammetrySession completed without a PointCloud payload."
        case let .missingIntrinsics(index):
            "Pose \(index) did not include camera intrinsics."
        case let .cannotReadImage(url):
            "Could not read image dimensions from \(url.path)."
        }
    }
}
