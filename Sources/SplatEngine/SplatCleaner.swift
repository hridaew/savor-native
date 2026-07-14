import Foundation
import PoseCore
import simd
import SplatIO

public struct SplatCleaningConfiguration: Sendable, Equatable {
    public var cellFactor: Float
    public var minimumNeighbors: Int
    public var faintAlpha: Float
    public var spikeScaleMultiplier: Float
    public var planeEpsilonFactor: Float
    public var framePercentile: Float
    public var nearFieldMultiplier: Float
    public var hazeAlpha: Float
    public var hazeSupportMultiplier: Int
    public var hazeClumpAlphaSupport: Float
    public var worldUp: SIMD3<Float>
    /// Isolate the orbited subject (connected-component within the camera
    /// orbit) for "Cleaned" mode. On by default; skipped for environment
    /// captures. Unlike the old radial crop this keeps thin attached parts
    /// (legs, arms) because it follows connectivity, not a hard radius.
    public var isolateSubject: Bool
    /// Isolation keep sphere as a fraction of the orbit radius. The subject
    /// sits inside the orbit, so mass beyond this is environment.
    public var subjectOrbitKeepFraction: Float
    /// Connectivity voxel edge as a fraction of the keep radius. Small enough
    /// to separate the subject from a detached background clump, large enough
    /// that the subject stays one connected component.
    public var subjectVoxelFactor: Float
    /// A voxel counts as subject surface when its summed alpha clears this
    /// fraction of the densest voxel's — filters sparse background voxels.
    public var subjectVoxelMassFloor: Float
    /// Retained for API/config compatibility; unused by the connected-component
    /// isolation that replaced the old radial density crop.
    public var subjectKeepMultiplier: Float
    public var orbitKeepFraction: Float
    public var densityPeakFraction: Float
    public var densityFloor: Float

    public init(
        cellFactor: Float = 0.1,
        minimumNeighbors: Int = 4,
        faintAlpha: Float = 0.04,
        spikeScaleMultiplier: Float = 8,
        planeEpsilonFactor: Float = 0.04,
        framePercentile: Float = 0.92,
        nearFieldMultiplier: Float = 2.2,
        hazeAlpha: Float = 0.08,
        hazeSupportMultiplier: Int = 2,
        hazeClumpAlphaSupport: Float = 100,
        worldUp: SIMD3<Float> = SIMD3(0, 1, 0),
        isolateSubject: Bool = true,
        subjectOrbitKeepFraction: Float = 0.95,
        subjectVoxelFactor: Float = 0.06,
        subjectVoxelMassFloor: Float = 0.03,
        subjectKeepMultiplier: Float = 1.08,
        orbitKeepFraction: Float = 0.75,
        densityPeakFraction: Float = 0.28,
        densityFloor: Float = 0.10
    ) {
        self.cellFactor = cellFactor
        self.minimumNeighbors = minimumNeighbors
        self.faintAlpha = faintAlpha
        self.spikeScaleMultiplier = spikeScaleMultiplier
        self.planeEpsilonFactor = planeEpsilonFactor
        self.framePercentile = framePercentile
        self.nearFieldMultiplier = nearFieldMultiplier
        self.hazeAlpha = hazeAlpha
        self.hazeSupportMultiplier = hazeSupportMultiplier
        self.hazeClumpAlphaSupport = hazeClumpAlphaSupport
        self.worldUp = worldUp
        self.isolateSubject = isolateSubject
        self.subjectOrbitKeepFraction = subjectOrbitKeepFraction
        self.subjectVoxelFactor = subjectVoxelFactor
        self.subjectVoxelMassFloor = subjectVoxelMassFloor
        self.subjectKeepMultiplier = subjectKeepMultiplier
        self.orbitKeepFraction = orbitKeepFraction
        self.densityPeakFraction = densityPeakFraction
        self.densityFloor = densityFloor
    }
}

public struct SplatCleaningResult: Sendable, Equatable {
    public let center: SIMD3<Float>
    public let radius: Float
    /// Normalized compact opaque-core radius (cleaned CRS).
    public let compactRadius: Float
    public let totalCount: Int
    public let keptCount: Int
    public let floaterCount: Int
    public let hazeRemovedCount: Int
    /// Points dropped by hard subject isolation (object captures only).
    public let subjectIsolatedCount: Int
    public let planeFound: Bool
    public let orbitRadius: Float
    public let isEnvironment: Bool
    public let cameraPosition: SIMD3<Float>?
    /// Up axis the cleanup used: camera-ring orbit axis when cameras were
    /// available, otherwise the configured worldUp.
    public let worldUp: SIMD3<Float>
}

struct CleanedSplatPoints {
    let points: [SplatPoint]
    let statistics: SplatCleaningResult
}

public enum SplatCleaner {
    public enum Error: LocalizedError {
        case emptyInput
        case outputAlreadyExists(URL)

        public var errorDescription: String? {
            switch self {
            case .emptyInput:
                "The raw splat contains no Gaussian points."
            case let .outputAlreadyExists(url):
                "Cleaned splat output already exists at \(url.path)."
            }
        }
    }

    private static let maximumGridLevel = 7

    public static func clean(
        inputURL: URL,
        outputURL: URL,
        cameraCenters: [SIMD3<Float>] = [],
        configuration: SplatCleaningConfiguration =
            SplatCleaningConfiguration()
    ) async throws -> SplatCleaningResult {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw Error.outputAlreadyExists(outputURL)
        }
        // MetalSplatter's binary PLY reader historically hung on zero-vertex
        // clouds; fail fast from the header before opening the stream.
        let headerHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? headerHandle.close() }
        let headerPrefix = try headerHandle.read(upToCount: 4_096) ?? Data()
        let vertexCount = (try? PLYHeaderReader.vertexCount(in: headerPrefix))
            ?? 0
        guard vertexCount > 0 else {
            throw Error.emptyInput
        }
        let reader = try AutodetectSceneReader(inputURL)
        let points = try await reader.readAll()
        try Task.checkCancellation()
        let cleaned = try cleanPoints(
            points,
            cameraCenters: cameraCenters,
            configuration: configuration
        )

        let parentURL = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        let stagingURL = parentURL.appendingPathComponent(
            ".\(outputURL.lastPathComponent).staging-\(UUID().uuidString)"
        )
        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }

        let degree = cleaned.points.first?.color.shDegree.rawValue ?? 0
        let writer = try SplatPLYSceneWriter(
            toFileAtPath: stagingURL.path
        )
        try await writer.start(
            sphericalHarmonicDegree: UInt(degree),
            pointCount: cleaned.points.count
        )
        try await writer.write(cleaned.points)
        try await writer.close()
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stagingURL, to: outputURL)
        committed = true
        try SplatFramingMetadata(cleaned.statistics).write(beside: outputURL)
        return cleaned.statistics
    }

    static func cleanPoints(
        _ points: [SplatPoint],
        cameraCenters: [SIMD3<Float>] = [],
        configuration: SplatCleaningConfiguration =
            SplatCleaningConfiguration()
    ) throws -> CleanedSplatPoints {
        guard !points.isEmpty else {
            throw Error.emptyInput
        }
        let count = points.count
        let positions = points.map(\.position)
        let alpha = points.map { $0.opacity.asLinearFloat }
        let scales = points.map { $0.scale.asLinearFloat }
        let sizes = scales.map { max($0.x, max($0.y, $0.z)) }
        let middleSizes = scales.map {
            $0.x + $0.y + $0.z - max($0.x, max($0.y, $0.z))
                - min($0.x, min($0.y, $0.z))
        }

        let initialCenter = SIMD3(
            median(positions.map(\.x)),
            median(positions.map(\.y)),
            median(positions.map(\.z))
        )
        let distances = positions.map { simd_length($0 - initialCenter) }
        let medianDistance = max(median(distances), 0.000_001)
        let baseCell = medianDistance * configuration.cellFactor

        var levels = [Int](repeating: 0, count: count)
        for index in points.indices {
            let rawLevel = Int(round(log2(max(sizes[index], baseCell) / baseCell)))
            levels[index] = min(maximumGridLevel, max(0, rawLevel))
        }
        let cellSizes = (0...maximumGridLevel).map {
            baseCell * pow(2, Float($0))
        }
        var countGrids = Array(
            repeating: [VoxelKey: Int](),
            count: maximumGridLevel + 1
        )
        var alphaGrids = Array(
            repeating: [VoxelKey: Float](),
            count: maximumGridLevel + 1
        )
        for index in points.indices {
            for level in 0...maximumGridLevel where levels[index] >= level - 2 {
                let key = voxelKey(positions[index], cellSize: cellSizes[level])
                countGrids[level][key, default: 0] += 1
                alphaGrids[level][key, default: 0] += alpha[index]
            }
        }

        func neighborhoodCount(_ index: Int) -> Int {
            let level = levels[index]
            let key = voxelKey(positions[index], cellSize: cellSizes[level])
            var value = 0
            for x in -1...1 {
                for y in -1...1 {
                    for z in -1...1 {
                        value += countGrids[level][key.offset(x, y, z), default: 0]
                    }
                }
            }
            return value - 1
        }

        func neighborhoodAlpha(_ index: Int) -> Float {
            let level = levels[index]
            let key = voxelKey(positions[index], cellSize: cellSizes[level])
            var value: Float = 0
            for x in -1...1 {
                for y in -1...1 {
                    for z in -1...1 {
                        value += alphaGrids[level][key.offset(x, y, z), default: 0]
                    }
                }
            }
            return value - alpha[index]
        }

        let medianSize = median(sizes)
        let needleSize = configuration.spikeScaleMultiplier * medianSize
        var isFloater = [Bool](repeating: false, count: count)
        var floaterCount = 0
        for index in points.indices {
            let support = neighborhoodCount(index)
            let small = levels[index] <= 2
            let lonely = support
                < (small ? configuration.minimumNeighbors : 1)
            let faintAndSparse = small
                && alpha[index] < configuration.faintAlpha
                && support < configuration.minimumNeighbors * 3
            let needle = sizes[index] > needleSize
                && middleSizes[index] < sizes[index] / 25
            if lonely || faintAndSparse || needle {
                isFloater[index] = true
                floaterCount += 1
            }
        }

        // The SfM world is not guaranteed upright: PhotogrammetrySession gets
        // EXIF-less JPEG frames with no gravity, so the configured worldUp is
        // a guess. The capture-camera ring is not — its orbit axis is gravity
        // to within the tilt of the operator's sweep.
        let derivedUp = estimateWorldUp(
            cameraCenters: cameraCenters,
            subjectCenter: initialCenter
        )
        let worldUp = derivedUp ?? simd_normalize(configuration.worldUp)
        let down = -worldUp
        let planeEpsilon = configuration.planeEpsilonFactor * medianDistance
        let subjectSizeCap = 0.5 * medianDistance
        let plane = estimateSupportPlane(
            positions: positions,
            sizes: sizes,
            distances: distances,
            isFloater: isFloater,
            center: initialCenter,
            down: down,
            subjectSizeCap: subjectSizeCap,
            epsilon: planeEpsilon,
            medianDistance: medianDistance
        )
        let planeCut = -0.35 * planeEpsilon
        func aboveness(_ index: Int) -> Float {
            guard let plane else {
                return -1
            }
            return simd_dot(plane.normal, positions[index]) - plane.distance
        }

        var subjectIndices: [Int] = []
        for index in points.indices {
            guard !isFloater[index] else {
                continue
            }
            guard sizes[index] <= subjectSizeCap else {
                continue
            }
            guard distances[index] <= 1.5 * medianDistance else {
                continue
            }
            if plane != nil, aboveness(index) > planeCut {
                continue
            }
            subjectIndices.append(index)
        }
        if subjectIndices.count <= 500 {
            subjectIndices = Array(points.indices)
        }
        let center = SIMD3(
            median(subjectIndices.map { positions[$0].x }),
            median(subjectIndices.map { positions[$0].y }),
            median(subjectIndices.map { positions[$0].z })
        )
        let subjectDistances = subjectIndices
            .map { simd_length(positions[$0] - center) }
            .sorted()
        let radius = max(
            percentile(subjectDistances, configuration.framePercentile),
            0.000_001
        )
        let compactSubjectIndices = subjectIndices.filter {
            sizes[$0] <= 2 * medianSize
        }
        let compactDistances = (
            compactSubjectIndices.isEmpty ? subjectIndices : compactSubjectIndices
        )
        .map { simd_length(positions[$0] - center) }
        .sorted()
        let compactRadius = max(
            percentile(compactDistances, 0.85),
            0.000_001
        )

        let orbitDistances = cameraCenters
            .map { simd_length($0 - center) }
            .sorted()
        let rawOrbitRadius = orbitDistances.isEmpty
            ? 0
            : orbitDistances[orbitDistances.count / 2]
        // Environment = cameras sit inside the scene's own opacity mass (an
        // inside-out capture of a room, whose walls lie beyond the camera
        // ring). Weight by alpha so sparse densification shells — few faint
        // points flung past the cameras — can't flip an object capture into
        // environment mode; percentile radii proved gameable by exactly that.
        var massEntries: [(distance: Float, weight: Float)] = []
        massEntries.reserveCapacity(count - floaterCount)
        var totalMass: Float = 0
        for index in points.indices where !isFloater[index] {
            let entry = (simd_length(positions[index] - center), alpha[index])
            massEntries.append(entry)
            totalMass += entry.1
        }
        massEntries.sort { $0.distance < $1.distance }
        var massRadius: Float = radius
        var accumulated: Float = 0
        for entry in massEntries {
            accumulated += entry.weight
            if accumulated >= totalMass * 0.5 {
                massRadius = entry.distance
                break
            }
        }
        let isEnvironment = rawOrbitRadius > 0
            && rawOrbitRadius < 1.05 * massRadius

        let hazeInnerRadius: Float
        let hazeOuterRadius: Float
        if rawOrbitRadius > 0 {
            // Keep the haze annulus between the compact core and the camera
            // ring even when densification floaters inflate the full radius
            // past the cameras (which previously flipped object captures into
            // "environment" mode and skipped cleanup entirely).
            hazeInnerRadius = min(1.3 * compactRadius, 0.55 * rawOrbitRadius)
            hazeOuterRadius = 0.9 * rawOrbitRadius
        } else {
            hazeInnerRadius = 1.3 * radius
            hazeOuterRadius = configuration.nearFieldMultiplier * radius
        }
        // Environment captures (cameras inside the scene's own extent) skip
        // the haze pass entirely: its geometry assumes cameras outside the
        // subject — inside a room it would eat the furniture.
        let shouldRunOrbitHaze = !isEnvironment
            && hazeOuterRadius > hazeInnerRadius
        var isHaze = [Bool](repeating: false, count: count)
        var hazeRemovedCount = 0
        if shouldRunOrbitHaze {
            for index in points.indices where !isFloater[index] {
                let distance = simd_length(positions[index] - center)
                guard distance >= hazeInnerRadius, distance <= hazeOuterRadius else {
                    continue
                }
                let above = plane == nil ? -Float.infinity : aboveness(index)
                if plane != nil,
                   above > planeCut,
                   above <= 4 * planeEpsilon {
                    continue
                }
                let alphaSupport = neighborhoodAlpha(index)
                if plane != nil, above > 4 * planeEpsilon {
                    if alphaSupport < configuration.hazeClumpAlphaSupport,
                       alpha[index] < 0.3 {
                        isHaze[index] = true
                        hazeRemovedCount += 1
                    }
                    continue
                }
                let support = neighborhoodCount(index)
                let giant = sizes[index] > subjectSizeCap
                let weakSmall = levels[index] <= 2
                    && support < configuration.hazeSupportMultiplier
                        * configuration.minimumNeighbors
                let faint = alpha[index] < configuration.hazeAlpha
                    && support < 3 * configuration.minimumNeighbors
                let bigLonely = levels[index] > 2 && support < 2
                let weakClump =
                    alphaSupport < configuration.hazeClumpAlphaSupport
                if giant || weakSmall || faint || bigLonely || weakClump {
                    isHaze[index] = true
                    hazeRemovedCount += 1
                }
            }
        }

        // Subject isolation (object captures): keep the dense splat mass that
        // is connected to the subject and sits inside the camera orbit; drop
        // the environment. An orbit necessarily surrounds its subject, so
        // anything beyond the orbit radius is provably not the subject (on
        // real captures ~40% of the reconstructed alpha-mass is environment
        // beyond the orbit). A 26-connected flood from the densest core then
        // drops detached background that falls inside the orbit sphere — e.g.
        // distant geometry the trainer placed at the wrong depth.
        //
        // Tables/floors are handled by column support, not by excluding the
        // whole plane: a table is a horizontal sheet whose outer parts have
        // nothing above them, whereas a subject's lower body (legs) always has
        // the torso in the same vertical column. So a below-plane voxel is kept
        // only when its column also holds above-plane occupancy. This trims a
        // tabletop without ever amputating legs — even when the support-plane
        // RANSAC mis-fits a horizontal band through the middle of a figure.
        var isOutsideSubject = [Bool](repeating: false, count: count)
        var subjectIsolatedCount = 0
        let shouldIsolate = configuration.isolateSubject
            && !isEnvironment
            && rawOrbitRadius > 0
        if shouldIsolate {
            let keepRadius = rawOrbitRadius * configuration.subjectOrbitKeepFraction
            let cell = keepRadius * configuration.subjectVoxelFactor
            func subjectKey(_ p: SIMD3<Float>) -> VoxelKey {
                voxelKey(p, cellSize: cell)
            }
            // Horizontal basis perpendicular to the capture's up axis.
            var horizontalU = simd_cross(worldUp, SIMD3<Float>(1, 0, 0))
            if simd_length(horizontalU) < 0.1 {
                horizontalU = simd_cross(worldUp, SIMD3<Float>(0, 0, 1))
            }
            horizontalU = simd_normalize(horizontalU)
            let horizontalV = simd_normalize(simd_cross(worldUp, horizontalU))
            func columnKey(_ p: SIMD3<Float>) -> Int64 {
                let d = p - center
                let a = Int64(floor(simd_dot(d, horizontalU) / cell))
                let b = Int64(floor(simd_dot(d, horizontalV) / cell))
                return a &* 1_000_003 &+ b
            }
            var postHazeCount = 0
            var voxelMass: [VoxelKey: Float] = [:]
            var voxelHasAbove: [VoxelKey: Bool] = [:]
            var voxelColumn: [VoxelKey: Int64] = [:]
            var columnsWithBodyAbove = Set<Int64>()
            for index in points.indices where !isFloater[index] && !isHaze[index] {
                postHazeCount += 1
                guard simd_length(positions[index] - center) <= keepRadius else {
                    continue
                }
                let key = subjectKey(positions[index])
                voxelMass[key, default: 0] += alpha[index]
                voxelColumn[key] = columnKey(positions[index])
                // "Above the surface" (or no plane at all) counts as body mass.
                if plane == nil || aboveness(index) <= planeCut {
                    voxelHasAbove[key] = true
                    columnsWithBodyAbove.insert(columnKey(positions[index]))
                }
            }
            let peakMass = voxelMass.values.max() ?? 0
            if peakMass > 0 {
                let massFloor = peakMass * configuration.subjectVoxelMassFloor
                var occupied = Set<VoxelKey>()
                for (key, mass) in voxelMass where mass >= massFloor {
                    // Drop a purely below-plane voxel only when nothing in its
                    // vertical column is above the plane (a table's outer sheet);
                    // a leg's column has the torso above it, so it survives.
                    if plane != nil,
                       voxelHasAbove[key] != true,
                       let column = voxelColumn[key],
                       !columnsWithBodyAbove.contains(column) {
                        continue
                    }
                    occupied.insert(key)
                }
                let centerKey = subjectKey(center)
                var seed: VoxelKey?
                var bestSeedDistance = Int.max
                for key in occupied {
                    let dx = key.x - centerKey.x
                    let dy = key.y - centerKey.y
                    let dz = key.z - centerKey.z
                    let distance = dx * dx + dy * dy + dz * dz
                    if distance < bestSeedDistance {
                        bestSeedDistance = distance
                        seed = key
                    }
                }
                var component = Set<VoxelKey>()
                if let seed {
                    var queue = [seed]
                    component.insert(seed)
                    var head = 0
                    while head < queue.count {
                        let key = queue[head]
                        head += 1
                        for dx in -1...1 {
                            for dy in -1...1 {
                                for dz in -1...1 {
                                    let neighbor = key.offset(dx, dy, dz)
                                    if occupied.contains(neighbor),
                                       !component.contains(neighbor) {
                                        component.insert(neighbor)
                                        queue.append(neighbor)
                                    }
                                }
                            }
                        }
                    }
                }
                for index in points.indices
                where !isFloater[index] && !isHaze[index] {
                    let inside = simd_length(positions[index] - center) <= keepRadius
                        && component.contains(subjectKey(positions[index]))
                    if !inside {
                        isOutsideSubject[index] = true
                        subjectIsolatedCount += 1
                    }
                }
                // Guard against a bad seed nuking the subject: real subjects
                // are 30–45% of the post-haze cloud, so keeping under 2% means
                // isolation failed — discard it and fall back to floater+haze.
                let keptAfterIsolation = postHazeCount - subjectIsolatedCount
                if keptAfterIsolation < postHazeCount / 50 {
                    isOutsideSubject = [Bool](repeating: false, count: count)
                    subjectIsolatedCount = 0
                }
            }
        }

        var keptIndices: [Int] = []
        keptIndices.reserveCapacity(count - floaterCount - hazeRemovedCount)
        for index in points.indices
        where !isFloater[index] && !isHaze[index] && !isOutsideSubject[index] {
            keptIndices.append(index)
        }
        if keptIndices.isEmpty {
            // Isolation was too aggressive; fall back to post-haze cloud.
            for index in points.indices where !isFloater[index] && !isHaze[index] {
                keptIndices.append(index)
                isOutsideSubject[index] = false
            }
            subjectIsolatedCount = 0
        }

        let keptDistances = keptIndices
            .map { simd_length(positions[$0] - center) }
            .sorted()
        let frameRadius = max(
            percentile(keptDistances, configuration.framePercentile),
            0.000_001
        )
        let keptCompactDistances = keptIndices
            .filter { sizes[$0] <= 2 * medianSize }
            .map { simd_length(positions[$0] - center) }
            .sorted()
        let frameCompactRadius = max(
            percentile(
                keptCompactDistances.isEmpty ? keptDistances : keptCompactDistances,
                0.85
            ),
            0.000_001
        )
        let normalization = 1 / frameRadius
        let logNormalization = log(normalization)
        var cleanedPoints: [SplatPoint] = []
        cleanedPoints.reserveCapacity(keptIndices.count)
        for index in keptIndices {
            var point = points[index]
            point.position = (point.position - center) * normalization
            point.scale = .exponent(
                point.scale.asExponent + SIMD3(repeating: logNormalization)
            )
            cleanedPoints.append(point)
        }

        let normalizedCameraPosition: SIMD3<Float>?
        if cameraCenters.isEmpty {
            normalizedCameraPosition = nil
        } else {
            let medianCameraPosition = SIMD3(
                median(cameraCenters.map(\.x)),
                median(cameraCenters.map(\.y)),
                median(cameraCenters.map(\.z))
            )
            normalizedCameraPosition =
                (medianCameraPosition - center) * normalization
        }

        return CleanedSplatPoints(
            points: cleanedPoints,
            statistics: SplatCleaningResult(
                center: center,
                radius: frameRadius,
                compactRadius: frameCompactRadius * normalization,
                totalCount: count,
                keptCount: cleanedPoints.count,
                floaterCount: floaterCount,
                hazeRemovedCount: hazeRemovedCount,
                subjectIsolatedCount: subjectIsolatedCount,
                planeFound: plane != nil,
                orbitRadius: rawOrbitRadius * normalization,
                isEnvironment: isEnvironment,
                cameraPosition: normalizedCameraPosition,
                worldUp: worldUp
            )
        )
    }

    /// Orbit-axis up estimate: sum of cross products of successive camera
    /// offsets around their centroid is the ring's axis (robust for the
    /// ring-like paths PoseSanity already enforces). Sign is chosen so the
    /// camera ring sits above the subject — captures orbit looking slightly
    /// down. Returns nil for too-few cameras or a degenerate (straight-line)
    /// path.
    private static func estimateWorldUp(
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

    private static func estimateSupportPlane(
        positions: [SIMD3<Float>],
        sizes: [Float],
        distances: [Float],
        isFloater: [Bool],
        center: SIMD3<Float>,
        down: SIMD3<Float>,
        subjectSizeCap: Float,
        epsilon: Float,
        medianDistance: Float
    ) -> Plane? {
        let candidates = positions.indices.filter {
            !isFloater[$0]
                && sizes[$0] < subjectSizeCap
                && distances[$0] < 8 * medianDistance
                && simd_dot(positions[$0] - center, down)
                    > -0.3 * medianDistance
        }
        guard candidates.count > 300 else {
            return nil
        }
        let sampleCount = min(candidates.count, 16_000)
        var generator = DeterministicGenerator(seed: 1_234_567)
        var bestPlane: Plane?
        var bestScore: Float = 0
        for _ in 0..<400 {
            let first = candidates[generator.nextIndex(upperBound: candidates.count)]
            let second = candidates[generator.nextIndex(upperBound: candidates.count)]
            let third = candidates[generator.nextIndex(upperBound: candidates.count)]
            let cross = simd_cross(
                positions[second] - positions[first],
                positions[third] - positions[first]
            )
            let length = simd_length(cross)
            guard length > 0.000_000_001 else {
                continue
            }
            var normal = cross / length
            guard abs(simd_dot(normal, down)) >= 0.85 else {
                continue
            }
            if simd_dot(normal, down) < 0 {
                normal = -normal
            }
            let planeDistance = simd_dot(normal, positions[first])
            var inlierCount = 0
            var downSum: Float = 0
            for sample in 0..<sampleCount {
                let index = candidates[
                    (sample &* 2_654_435_761) % candidates.count
                ]
                let delta = simd_dot(normal, positions[index]) - planeDistance
                if abs(delta) < epsilon {
                    inlierCount += 1
                    downSum += simd_dot(positions[index] - center, down)
                }
            }
            guard inlierCount >= Int(Float(sampleCount) * 0.02) else {
                continue
            }
            let averageDown = downSum / Float(inlierCount)
            let relativeDepth = max(0, averageDown / medianDistance)
            let score = Float(inlierCount)
                / (1 + 3 * relativeDepth * relativeDepth)
            if score > bestScore {
                bestScore = score
                bestPlane = Plane(normal: normal, distance: planeDistance)
            }
        }
        return bestPlane
    }

    private static func voxelKey(
        _ position: SIMD3<Float>,
        cellSize: Float
    ) -> VoxelKey {
        VoxelKey(
            x: Int(floor(position.x / cellSize)),
            y: Int(floor(position.y / cellSize)),
            z: Int(floor(position.z / cellSize))
        )
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) * 0.5
            : sorted[middle]
    }

    private static func percentile(
        _ sorted: [Float],
        _ percentile: Float
    ) -> Float {
        let index = min(
            sorted.count - 1,
            Int(Float(sorted.count) * min(1, max(0, percentile)))
        )
        return sorted[index]
    }
}

private struct VoxelKey: Hashable {
    let x: Int
    let y: Int
    let z: Int

    func offset(_ x: Int, _ y: Int, _ z: Int) -> VoxelKey {
        VoxelKey(x: self.x + x, y: self.y + y, z: self.z + z)
    }
}

private struct Plane {
    let normal: SIMD3<Float>
    let distance: Float
}

private struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextIndex(upperBound: Int) -> Int {
        state = (state &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff
        return Int(state % UInt64(upperBound))
    }
}
