import Foundation
import simd

public enum SplatSceneFramingResolver {
    /// Prefer cleaned `framing.json` metadata; otherwise opaque point framing
    /// with an optional transforms camera-ring when CRS scales match.
    public static func resolve(
        positions: [SIMD3<Float>],
        opacities: [Float],
        maxLinearScales: [Float],
        metadata: SplatFramingMetadata?,
        transformsURL: URL?
    ) throws -> SplatSceneFraming {
        if let metadata {
            return try SplatSceneFraming(cleanedMetadata: metadata)
        }

        let pointFraming = try SplatSceneFraming(
            positions: positions,
            opacities: opacities,
            maxLinearScales: maxLinearScales
        )
        guard let transformsURL else {
            return pointFraming
        }
        let cameraCenters = TransformsCameraCenters.load(from: transformsURL)
        guard !cameraCenters.isEmpty else {
            return pointFraming
        }
        let candidate = try SplatSceneFraming(
            cameraCenters: cameraCenters,
            subjectHint: pointFraming.center
        )
        // Cleaned/normalized scenes live in a different CRS than the capture
        // transforms. Fall back to point framing when the camera ring no
        // longer matches the splat extent.
        let scaleRatio = candidate.radius / max(pointFraming.radius, 0.001)
        if scaleRatio > 0.35 && scaleRatio < 2.5 {
            return candidate
        }
        return pointFraming
    }
}
