import Foundation
import simd
import SplatIO

/// Contiguous CPU buffers matching the WWDC26 RealityKit
/// `GaussianSplatResource.BufferResource` layout (macOS 27+).
public struct SplatGPUBuffers: Sendable, Equatable {
    public let count: Int
    public let sphericalHarmonicsDegree: Int
    /// Packed XYZ floats (`count * 3`).
    public let positions: [Float]
    /// Packed XYZ linear scales (`count * 3`).
    public let scales: [Float]
    /// Packed XYZW unit quaternions (`count * 4`).
    public let rotations: [Float]
    /// Linear opacities (`count`).
    public let opacities: [Float]
    /// Interleaved SH RGB coefficients (`count * coefficientsPerSplat * 3`).
    public let sphericalHarmonics: [Float]

    public var coefficientsPerSplat: Int {
        let degree = max(0, sphericalHarmonicsDegree)
        return (degree + 1) * (degree + 1)
    }

    public init(
        count: Int,
        sphericalHarmonicsDegree: Int,
        positions: [Float],
        scales: [Float],
        rotations: [Float],
        opacities: [Float],
        sphericalHarmonics: [Float]
    ) {
        self.count = count
        self.sphericalHarmonicsDegree = sphericalHarmonicsDegree
        self.positions = positions
        self.scales = scales
        self.rotations = rotations
        self.opacities = opacities
        self.sphericalHarmonics = sphericalHarmonics
    }

    public static func make(from points: [SplatPoint]) -> SplatGPUBuffers {
        let count = points.count
        guard count > 0 else {
            return SplatGPUBuffers(
                count: 0,
                sphericalHarmonicsDegree: 0,
                positions: [],
                scales: [],
                rotations: [],
                opacities: [],
                sphericalHarmonics: []
            )
        }
        let degree = Int(
            points.map(\.color.shDegree.rawValue).max() ?? 0
        )
        let coeffsPerSplat = (degree + 1) * (degree + 1)
        var positions = [Float]()
        var scales = [Float]()
        var rotations = [Float]()
        var opacities = [Float]()
        var sphericalHarmonics = [Float]()
        positions.reserveCapacity(count * 3)
        scales.reserveCapacity(count * 3)
        rotations.reserveCapacity(count * 4)
        opacities.reserveCapacity(count)
        sphericalHarmonics.reserveCapacity(count * coeffsPerSplat * 3)

        for point in points {
            let position = point.position
            positions.append(position.x)
            positions.append(position.y)
            positions.append(position.z)

            let scale = point.scale.asLinearFloat
            scales.append(scale.x)
            scales.append(scale.y)
            scales.append(scale.z)

            let rotation = point.rotation.normalized
            rotations.append(rotation.imag.x)
            rotations.append(rotation.imag.y)
            rotations.append(rotation.imag.z)
            rotations.append(rotation.real)

            opacities.append(point.opacity.asLinearFloat)

            var coefficients = point.color.asSphericalHarmonicFloat
            if coefficients.count < coeffsPerSplat {
                coefficients.append(
                    contentsOf: Array(
                        repeating: SIMD3<Float>.zero,
                        count: coeffsPerSplat - coefficients.count
                    )
                )
            }
            for index in 0..<coeffsPerSplat {
                let rgb = coefficients[index]
                sphericalHarmonics.append(rgb.x)
                sphericalHarmonics.append(rgb.y)
                sphericalHarmonics.append(rgb.z)
            }
        }

        return SplatGPUBuffers(
            count: count,
            sphericalHarmonicsDegree: degree,
            positions: positions,
            scales: scales,
            rotations: rotations,
            opacities: opacities,
            sphericalHarmonics: sphericalHarmonics
        )
    }
}

/*
 RealityKit attach sketch (macOS / visionOS 27+ SDK — not available on
 macOS 26.2 / Xcode 26.3). When the SDK ships `GaussianSplatResource`,
 wire roughly:

   let buffers = SplatGPUBuffers.make(from: points)
   let position = /* MTLBuffer from buffers.positions */
   let scale = /* MTLBuffer from buffers.scales */
   let rotation = /* MTLBuffer from buffers.rotations */
   let opacity = /* MTLBuffer from buffers.opacities */
   let sh = /* MTLBuffer from buffers.sphericalHarmonics */
   let resource = try GaussianSplatResource.BufferResource(
       count: buffers.count,
       position: position,
       scale: scale,
       rotation: rotation,
       opacity: opacity,
       sphericalHarmonics: (sh, buffers.sphericalHarmonicsDegree)
   )
   let component = GaussianSplatComponent(GaussianSplatResource(resource))
   entity.components.set(component)

 Until then, MetalSplatter remains the shipping viewer.
 */
