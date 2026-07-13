import Foundation
import PoseCore

public struct PoseEstimationResult: Equatable, Sendable {
    public let frames: [DatasetFrame]
    public let points: [PointCloudPoint]
    public let totalImageCount: Int
    /// Best-effort Object Capture mesh; nil when unavailable or skipped.
    public let meshURL: URL?

    public init(
        frames: [DatasetFrame],
        points: [PointCloudPoint],
        totalImageCount: Int,
        meshURL: URL? = nil
    ) {
        self.frames = frames
        self.points = points
        self.totalImageCount = totalImageCount
        self.meshURL = meshURL
    }
}

public enum PoseDatasetWriter {
    public static func write(
        _ result: PoseEstimationResult,
        imagesURL: URL,
        to outputURL: URL
    ) throws {
        try DatasetArtifactWriter.write(
            frames: result.frames,
            totalImageCount: result.totalImageCount,
            points: result.points,
            imagesURL: imagesURL,
            to: outputURL
        )
    }
}
