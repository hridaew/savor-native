import Foundation
import simd

/// Orbit-axis up estimate from a capture's camera ring. The SfM world is not
/// guaranteed upright (PhotogrammetrySession gets EXIF-less JPEG frames with
/// no gravity), but the ring is: its orbit axis is gravity to within the tilt
/// of the operator's sweep. Used by the cleaner for plane logic and by the
/// viewer to orient scenes right-side-up automatically.
public enum OrbitUpEstimator {
    /// Sum of cross products of successive camera offsets around their
    /// centroid is the ring's axis (robust for the ring-like paths PoseSanity
    /// already enforces). Sign is chosen so the camera ring sits above the
    /// subject — captures orbit looking slightly down. Returns nil for
    /// too-few cameras or a degenerate (straight-line) path.
    public static func estimate(
        cameraCenters: [SIMD3<Float>],
        subjectCenter: SIMD3<Float>
    ) -> SIMD3<Float>? {
        guard cameraCenters.count >= 8 else {
            return nil
        }
        let centroid = cameraCenters.reduce(SIMD3<Float>.zero, +)
            / Float(cameraCenters.count)
        var axis = SIMD3<Float>.zero
        for index in 1..<cameraCenters.count {
            axis += simd_cross(
                cameraCenters[index - 1] - centroid,
                cameraCenters[index] - centroid
            )
        }
        let length = simd_length(axis)
        let spread = cameraCenters
            .map { simd_length($0 - centroid) }
            .max() ?? 0
        guard spread > 0, length > 0.1 * spread * spread else {
            return nil
        }
        axis /= length
        if simd_dot(axis, centroid - subjectCenter) < 0 {
            axis = -axis
        }
        return axis
    }
}
