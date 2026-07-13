import Foundation
import simd

public struct CameraIntrinsics: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let focalLengthX: Double
    public let focalLengthY: Double
    public let principalPointX: Double
    public let principalPointY: Double

    public init(
        width: Int,
        height: Int,
        focalLengthX: Double,
        focalLengthY: Double,
        principalPointX: Double,
        principalPointY: Double
    ) {
        self.width = width
        self.height = height
        self.focalLengthX = focalLengthX
        self.focalLengthY = focalLengthY
        self.principalPointX = principalPointX
        self.principalPointY = principalPointY
    }

    public init(
        matrix: simd_float3x3,
        imageWidth: Int,
        imageHeight: Int
    ) {
        width = imageWidth
        height = imageHeight
        focalLengthX = Double(matrix.columns.0.x)
        focalLengthY = Double(matrix.columns.1.y)
        principalPointX = Double(matrix.columns.2.x)
        principalPointY = Double(matrix.columns.2.y)
    }
}

public struct DatasetFrame: Equatable, Sendable {
    public let imagePath: String
    public let intrinsics: CameraIntrinsics
    public let cameraToWorld: Matrix4x4

    public init(
        imagePath: String,
        intrinsics: CameraIntrinsics,
        cameraToWorld: Matrix4x4
    ) {
        self.imagePath = imagePath
        self.intrinsics = intrinsics
        self.cameraToWorld = cameraToWorld
    }
}

public enum NerfstudioDatasetEncoder {
    public static func encode(
        frames: [DatasetFrame],
        pointCloudPath: String
    ) throws -> Data {
        let payload = Payload(
            cameraModel: "OPENCV",
            frames: frames.map(Frame.init),
            pointCloudPath: pointCloudPath
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

private struct Payload: Encodable {
    let cameraModel: String
    let frames: [Frame]
    let pointCloudPath: String

    enum CodingKeys: String, CodingKey {
        case cameraModel = "camera_model"
        case frames
        case pointCloudPath = "ply_file_path"
    }
}

private struct Frame: Encodable {
    let filePath: String
    let width: Int
    let height: Int
    let focalLengthX: Double
    let focalLengthY: Double
    let principalPointX: Double
    let principalPointY: Double
    let transformMatrix: [[Double]]

    init(_ frame: DatasetFrame) {
        filePath = frame.imagePath
        width = frame.intrinsics.width
        height = frame.intrinsics.height
        focalLengthX = frame.intrinsics.focalLengthX
        focalLengthY = frame.intrinsics.focalLengthY
        principalPointX = frame.intrinsics.principalPointX
        principalPointY = frame.intrinsics.principalPointY
        transformMatrix = frame.cameraToWorld.rows
    }

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case width = "w"
        case height = "h"
        case focalLengthX = "fl_x"
        case focalLengthY = "fl_y"
        case principalPointX = "cx"
        case principalPointY = "cy"
        case transformMatrix = "transform_matrix"
    }
}
