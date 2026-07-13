import Foundation
import simd

public struct SplatSceneFraming: Sendable, Equatable {
    public enum Error: Swift.Error {
        case noPositions
    }

    public let center: SIMD3<Float>
    public let radius: Float

    public init(
        positions: [SIMD3<Float>],
        opacities: [Float]? = nil,
        maxLinearScales: [Float]? = nil,
        minimumOpacity: Float = 0.15,
        maximumLinearScale: Float = 0.05,
        radiusPercentile: Float = 0.65
    ) throws {
        guard !positions.isEmpty else {
            throw Error.noPositions
        }

        let selectedPositions = Self.selectPositions(
            positions: positions,
            opacities: opacities,
            maxLinearScales: maxLinearScales,
            minimumOpacity: minimumOpacity,
            maximumLinearScale: maximumLinearScale
        )

        let resolvedCenter = SIMD3(
            Self.median(selectedPositions.map(\.x)),
            Self.median(selectedPositions.map(\.y)),
            Self.median(selectedPositions.map(\.z))
        )
        center = resolvedCenter
        let distances = selectedPositions
            .map { simd_length($0 - resolvedCenter) }
            .sorted()
        let percentile = min(1, max(0, radiusPercentile))
        let index = min(
            distances.count - 1,
            Int(Float(distances.count - 1) * percentile)
        )
        radius = max(distances[index], 0.1)
    }

    /// Frames the orbit camera using the capture camera ring when available.
    public init(
        cameraCenters: [SIMD3<Float>],
        subjectHint: SIMD3<Float>? = nil
    ) throws {
        guard !cameraCenters.isEmpty else {
            throw Error.noPositions
        }
        let resolvedCenter = subjectHint ?? SIMD3(
            Self.median(cameraCenters.map(\.x)),
            Self.median(cameraCenters.map(\.y)),
            Self.median(cameraCenters.map(\.z))
        )
        center = resolvedCenter
        let distances = cameraCenters
            .map { simd_length($0 - resolvedCenter) }
            .sorted()
        radius = max(distances[distances.count / 2] * 0.85, 0.1)
    }

    /// Frames a cleaned/normalized scene using compact-core metadata.
    public init(cleanedMetadata metadata: SplatFramingMetadata) throws {
        guard metadata.compactRadius > 0 else {
            throw Error.noPositions
        }
        center = .zero
        var fitRadius = metadata.compactRadius * 0.95
        if metadata.orbitRadius > 0 {
            let ratio = metadata.orbitRadius
                / max(metadata.compactRadius, 0.001)
            if ratio > 1.05 && ratio < 8 {
                fitRadius = min(fitRadius, metadata.orbitRadius * 0.55)
            }
        }
        radius = max(fitRadius, 0.1)
    }

    private static func selectPositions(
        positions: [SIMD3<Float>],
        opacities: [Float]?,
        maxLinearScales: [Float]?,
        minimumOpacity: Float,
        maximumLinearScale: Float
    ) -> [SIMD3<Float>] {
        let minimumKeep = max(32, positions.count / 50)
        if let opacities,
           let maxLinearScales,
           opacities.count == positions.count,
           maxLinearScales.count == positions.count {
            let filtered = zip(zip(positions, opacities), maxLinearScales)
                .compactMap { positionOpacity, scale -> SIMD3<Float>? in
                    let (position, opacity) = positionOpacity
                    guard opacity >= minimumOpacity,
                          scale <= maximumLinearScale
                    else {
                        return nil
                    }
                    return position
                }
            if filtered.count >= minimumKeep {
                return filtered
            }
        }
        if let opacities, opacities.count == positions.count {
            let filtered = zip(positions, opacities)
                .compactMap { position, opacity in
                    opacity >= minimumOpacity ? position : nil
                }
            if filtered.count >= minimumKeep {
                return filtered
            }
        }
        return positions
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }
}
