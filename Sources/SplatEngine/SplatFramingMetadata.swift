import Foundation
import simd

/// Cleaned-space framing written beside `scene-hq.ply` as `framing.json`.
public struct SplatFramingMetadata: Codable, Sendable, Equatable {
    public static let fileName = "framing.json"

    /// Normalized compact opaque-core radius (cleaned CRS).
    public let compactRadius: Float
    /// Normalized median camera-ring distance (cleaned CRS); 0 if unknown.
    public let orbitRadius: Float
    /// Normalized subject frame radius after clean (typically ~1).
    public let radius: Float
    /// Points dropped by hard subject isolation, if recorded.
    public let subjectIsolatedCount: Int?
    /// Median camera position in cleaned CRS, if available.
    public let cameraPosition: [Float]?
    public let isEnvironment: Bool
    /// World-up axis the cleanup used (camera-ring orbit axis when known);
    /// absent in metadata written before it was recorded.
    public let worldUp: [Float]?

    public init(
        compactRadius: Float,
        orbitRadius: Float,
        radius: Float,
        cameraPosition: SIMD3<Float>?,
        isEnvironment: Bool,
        subjectIsolatedCount: Int? = nil,
        worldUp: SIMD3<Float>? = nil
    ) {
        self.compactRadius = compactRadius
        self.orbitRadius = orbitRadius
        self.radius = radius
        self.subjectIsolatedCount = subjectIsolatedCount
        if let cameraPosition {
            self.cameraPosition = [
                cameraPosition.x,
                cameraPosition.y,
                cameraPosition.z,
            ]
        } else {
            self.cameraPosition = nil
        }
        self.isEnvironment = isEnvironment
        if let worldUp {
            self.worldUp = [worldUp.x, worldUp.y, worldUp.z]
        } else {
            self.worldUp = nil
        }
    }

    public init(_ result: SplatCleaningResult) {
        self.init(
            compactRadius: result.compactRadius,
            orbitRadius: result.orbitRadius,
            radius: 1,
            cameraPosition: result.cameraPosition,
            isEnvironment: result.isEnvironment,
            subjectIsolatedCount: result.subjectIsolatedCount,
            worldUp: result.worldUp
        )
    }

    public var cameraPositionVector: SIMD3<Float>? {
        guard let cameraPosition, cameraPosition.count == 3 else {
            return nil
        }
        return SIMD3(
            cameraPosition[0],
            cameraPosition[1],
            cameraPosition[2]
        )
    }

    public var worldUpVector: SIMD3<Float>? {
        guard let worldUp, worldUp.count == 3 else {
            return nil
        }
        return SIMD3(worldUp[0], worldUp[1], worldUp[2])
    }

    public static func url(beside plyURL: URL) -> URL {
        plyURL
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

    public static func load(near plyURL: URL) -> SplatFramingMetadata? {
        let url = Self.url(beside: plyURL)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(SplatFramingMetadata.self, from: data)
    }

    public func write(beside plyURL: URL) throws {
        let url = Self.url(beside: plyURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
