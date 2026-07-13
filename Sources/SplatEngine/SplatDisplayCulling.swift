import Foundation
import simd
import SplatIO

/// Display-path peripheral cull applied on open (does not rewrite the PLY).
public enum SplatDisplayCulling {
    public static let peripheralMultiplier: Float = 1.35
    public static let minimumOpacity: Float = 0.15
    public static let maximumLinearScale: Float = 0.05

    /// Drops haze-like points outside the compact core (or framing radius).
    public static func filterForDisplay(
        points: [SplatPoint],
        compactRadius: Float?,
        framingRadius: Float
    ) -> [SplatPoint] {
        guard !points.isEmpty else {
            return points
        }
        let outerLimit: Float
        if let compactRadius, compactRadius > 0 {
            outerLimit = compactRadius * peripheralMultiplier
        } else {
            outerLimit = max(framingRadius, 0.1)
        }

        return points.filter { point in
            let distance = simd_length(point.position)
            if distance <= outerLimit {
                return true
            }
            let opacity = point.opacity.asLinearFloat
            let scale = point.scale.asLinearFloat
            let maxScale = max(scale.x, max(scale.y, scale.z))
            let hazeLike = opacity < minimumOpacity
                || maxScale > maximumLinearScale
            return !hazeLike
        }
    }
}
