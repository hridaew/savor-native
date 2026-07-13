import Foundation
import simd

public enum TransformsCameraCenters {
    public static func load(from transformsURL: URL) -> [SIMD3<Float>] {
        guard
            let data = try? Data(contentsOf: transformsURL),
            let payload = try? JSONDecoder().decode(
                Payload.self,
                from: data
            )
        else {
            return []
        }
        return payload.frames.compactMap { frame in
            let rows = frame.transformMatrix
            guard
                rows.count >= 3,
                rows[0].count >= 4,
                rows[1].count >= 4,
                rows[2].count >= 4
            else {
                return nil
            }
            return SIMD3(
                Float(rows[0][3]),
                Float(rows[1][3]),
                Float(rows[2][3])
            )
        }
    }

    public static func resolveTransformsURL(
        near splatURL: URL
    ) -> URL? {
        let fileManager = FileManager.default
        var directory = splatURL.deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = directory.appendingPathComponent(
                "dataset/transforms.json"
            )
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            let direct = directory.appendingPathComponent("transforms.json")
            if fileManager.fileExists(atPath: direct.path) {
                return direct
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private struct Payload: Decodable {
        let frames: [Frame]
    }

    private struct Frame: Decodable {
        let transformMatrix: [[Double]]

        enum CodingKeys: String, CodingKey {
            case transformMatrix = "transform_matrix"
        }
    }
}
