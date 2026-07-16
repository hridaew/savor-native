import Foundation
import simd

/// Full per-frame camera data from a Nerfstudio `transforms.json` —
/// intrinsics plus camera-to-world pose. `TransformsCameraCenters` stays the
/// lightweight positions-only reader; this one feeds mask reprojection.
public struct CaptureTransforms: Sendable {
    public struct Frame: Sendable {
        public let imagePath: String
        public let width: Int
        public let height: Int
        public let focalLengthX: Float
        public let focalLengthY: Float
        public let principalPointX: Float
        public let principalPointY: Float
        /// OpenGL-convention camera-to-world (camera looks down −Z, +Y up),
        /// as written by the pose dataset writer.
        public let cameraToWorld: simd_float4x4

        public var worldToCamera: simd_float4x4 {
            cameraToWorld.inverse
        }

        public var cameraPosition: SIMD3<Float> {
            SIMD3(
                cameraToWorld.columns.3.x,
                cameraToWorld.columns.3.y,
                cameraToWorld.columns.3.z
            )
        }
    }

    public let frames: [Frame]

    public static func load(from transformsURL: URL) -> CaptureTransforms? {
        guard
            let data = try? Data(contentsOf: transformsURL),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return nil
        }
        let frames = payload.frames.compactMap { frame -> Frame? in
            let rows = frame.transformMatrix
            guard
                rows.count == 4,
                rows.allSatisfy({ $0.count == 4 })
            else {
                return nil
            }
            var columns = [SIMD4<Float>]()
            for column in 0..<4 {
                columns.append(SIMD4(
                    Float(rows[0][column]),
                    Float(rows[1][column]),
                    Float(rows[2][column]),
                    Float(rows[3][column])
                ))
            }
            return Frame(
                imagePath: frame.filePath,
                width: frame.width,
                height: frame.height,
                focalLengthX: Float(frame.focalLengthX),
                focalLengthY: Float(frame.focalLengthY),
                principalPointX: Float(frame.principalPointX),
                principalPointY: Float(frame.principalPointY),
                cameraToWorld: simd_float4x4(
                    columns[0],
                    columns[1],
                    columns[2],
                    columns[3]
                )
            )
        }
        guard !frames.isEmpty else {
            return nil
        }
        return CaptureTransforms(frames: frames)
    }

    private struct Payload: Decodable {
        let frames: [PayloadFrame]
    }

    private struct PayloadFrame: Decodable {
        let filePath: String
        let width: Int
        let height: Int
        let focalLengthX: Double
        let focalLengthY: Double
        let principalPointX: Double
        let principalPointY: Double
        let transformMatrix: [[Double]]

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
}
