import simd

public struct Vector3: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct Matrix4x4: Equatable, Sendable {
    public enum Error: Swift.Error, Equatable {
        case invalidShape
    }

    public let rows: [[Double]]

    public init(rows: [[Double]]) throws {
        guard rows.count == 4, rows.allSatisfy({ $0.count == 4 }) else {
            throw Error.invalidShape
        }
        self.rows = rows
    }

    public init(cameraTranslation: SIMD3<Float>, rotation: simd_quatf) {
        var transform = simd_float4x4(rotation)
        transform.columns.3 = SIMD4<Float>(
            cameraTranslation.x,
            cameraTranslation.y,
            cameraTranslation.z,
            1
        )
        rows = (0..<4).map { row in
            (0..<4).map { column in
                Double(transform[column][row])
            }
        }
    }

    public var cameraPosition: Vector3 {
        Vector3(x: rows[0][3], y: rows[1][3], z: rows[2][3])
    }

    public var openGLForward: Vector3 {
        Vector3(x: -rows[0][2], y: -rows[1][2], z: -rows[2][2])
    }
}

public struct PoseFrame: Equatable, Sendable {
    public let imageName: String
    public let cameraToWorld: Matrix4x4

    public init(imageName: String, cameraToWorld: Matrix4x4) {
        self.imageName = imageName
        self.cameraToWorld = cameraToWorld
    }
}

public enum PoseSanity {
    public enum Error: Swift.Error, Equatable {
        case insufficientCoverage(actual: Double, minimum: Double)
        case emptyPointCloud
        case camerasNotFacingPointCloud(actual: Double, minimum: Double)
        case cameraPathNotRingLike(actual: Double, minimum: Double)
    }

    public static func validate(
        frames: [PoseFrame],
        totalImageCount: Int,
        points: [Vector3],
        minimumCoverage: Double = 0.9
    ) throws {
        let coverage = totalImageCount > 0
            ? Double(frames.count) / Double(totalImageCount)
            : 0
        guard coverage >= minimumCoverage else {
            throw Error.insufficientCoverage(actual: coverage, minimum: minimumCoverage)
        }

        guard !points.isEmpty else {
            throw Error.emptyPointCloud
        }
        guard !frames.isEmpty else {
            return
        }

        let pointCount = Double(points.count)
        let centroid = Vector3(
            x: points.reduce(0) { $0 + $1.x } / pointCount,
            y: points.reduce(0) { $0 + $1.y } / pointCount,
            z: points.reduce(0) { $0 + $1.z } / pointCount
        )
        let facingCount = frames.count { frame in
            let position = frame.cameraToWorld.cameraPosition
            let forward = frame.cameraToWorld.openGLForward
            let toward = Vector3(
                x: centroid.x - position.x,
                y: centroid.y - position.y,
                z: centroid.z - position.z
            )
            let dot = forward.x * toward.x + forward.y * toward.y + forward.z * toward.z
            return dot > 0
        }
        let facingFraction = Double(facingCount) / Double(frames.count)
        let minimumFacingFraction = 0.9
        guard facingFraction >= minimumFacingFraction else {
            throw Error.camerasNotFacingPointCloud(
                actual: facingFraction,
                minimum: minimumFacingFraction
            )
        }

        guard frames.count >= 3 else {
            return
        }
        let radii = frames.map { frame in
            let position = frame.cameraToWorld.cameraPosition
            let x = position.x - centroid.x
            let y = position.y - centroid.y
            let z = position.z - centroid.z
            return (x * x + y * y + z * z).squareRoot()
        }
        let sortedRadii = radii.sorted()
        let medianRadius = sortedRadii[sortedRadii.count / 2]
        let ringLikeCount = radii.count { radius in
            medianRadius > 0
                && radius >= medianRadius * 0.25
                && radius <= medianRadius * 4
        }
        let ringLikeFraction = Double(ringLikeCount) / Double(radii.count)
        let minimumRingLikeFraction = 0.9
        guard ringLikeFraction >= minimumRingLikeFraction else {
            throw Error.cameraPathNotRingLike(
                actual: ringLikeFraction,
                minimum: minimumRingLikeFraction
            )
        }
    }
}
