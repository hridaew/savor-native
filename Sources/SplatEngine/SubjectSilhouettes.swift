import Foundation
import simd

/// Per-view subject silhouettes (binary masks + the cameras that shot them),
/// used to carve the splat down to the filmed subject by multi-view
/// consensus: a 3D point belongs to the subject only if it projects inside
/// the subject's silhouette from (nearly) every camera that sees it — the
/// classical visual hull. Unlike density/connectivity heuristics this
/// separates attached environment (pedestal edges, floor shadows) and
/// near-surface fog from the subject, because those fall outside the
/// silhouette in side views even when they touch the subject in 3D.
public struct SubjectSilhouettes: Sendable {
    public struct View: Sendable {
        /// OpenGL-convention world-to-camera (camera looks down −Z, +Y up).
        public let worldToCamera: simd_float4x4
        /// Intrinsics at the original image resolution.
        public let focalLengthX: Float
        public let focalLengthY: Float
        public let principalPointX: Float
        public let principalPointY: Float
        public let imageWidth: Float
        public let imageHeight: Float
        /// Row-major binary mask, downsampled from the image; true = subject.
        public let mask: [Bool]
        public let maskWidth: Int
        public let maskHeight: Int

        public init(
            worldToCamera: simd_float4x4,
            focalLengthX: Float,
            focalLengthY: Float,
            principalPointX: Float,
            principalPointY: Float,
            imageWidth: Float,
            imageHeight: Float,
            mask: [Bool],
            maskWidth: Int,
            maskHeight: Int
        ) {
            self.worldToCamera = worldToCamera
            self.focalLengthX = focalLengthX
            self.focalLengthY = focalLengthY
            self.principalPointX = principalPointX
            self.principalPointY = principalPointY
            self.imageWidth = imageWidth
            self.imageHeight = imageHeight
            self.mask = mask
            self.maskWidth = maskWidth
            self.maskHeight = maskHeight
        }

        /// Mask cell a world point projects into, or nil when it falls
        /// outside the view frustum (or behind the camera).
        func maskCellIndex(_ world: SIMD3<Float>) -> Int? {
            let camera = worldToCamera * SIMD4(world, 1)
            // OpenGL camera: in front means negative Z.
            let depth = -camera.z
            guard depth > 0.001 else {
                return nil
            }
            let u = principalPointX + focalLengthX * (camera.x / depth)
            let v = principalPointY - focalLengthY * (camera.y / depth)
            guard u >= 0, u < imageWidth, v >= 0, v < imageHeight else {
                return nil
            }
            let x = min(
                maskWidth - 1,
                Int(u * Float(maskWidth) / imageWidth)
            )
            let y = min(
                maskHeight - 1,
                Int(v * Float(maskHeight) / imageHeight)
            )
            return y * maskWidth + x
        }

        /// Classifies a world point against this view: outside the frustum
        /// (or behind the camera) → `nil`; otherwise whether it lands on the
        /// subject's silhouette.
        public func subjectHit(_ world: SIMD3<Float>) -> Bool? {
            guard let index = maskCellIndex(world) else {
                return nil
            }
            return mask[index]
        }
    }

    public let views: [View]

    public init(views: [View]) {
        self.views = views
    }

    /// Fraction of views (that see the point at all) where it lands on the
    /// subject, and how many views saw it. Subject points score ~1 by the
    /// silhouette property; environment scores ~0.
    public func consensus(
        for world: SIMD3<Float>
    ) -> (ratio: Float, seenBy: Int) {
        var seen = 0
        var hits = 0
        for view in views {
            guard let hit = view.subjectHit(world) else {
                continue
            }
            seen += 1
            if hit {
                hits += 1
            }
        }
        guard seen > 0 else {
            return (0, 0)
        }
        return (Float(hits) / Float(seen), seen)
    }
}
