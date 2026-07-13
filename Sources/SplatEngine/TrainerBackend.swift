import Foundation

public struct TrainingOptions: Sendable, Equatable {
    public let totalSteps: Int
    public let sphericalHarmonicsDegree: Int
    public let exportInterval: Int
    public let keepCoordinateSystem: Bool
    public let refineEvery: Int
    public let warmupLength: Int
    public let resetAlphaEvery: Int
    public let densifyGradThresh: Float
    public let densifySizeThresh: Float
    public let stopScreenSizeAt: Int
    public let splitScreenSize: Float

    /// Schedule constraint: msplat resets every splat's opacity to near-zero
    /// every `refineEvery * resetAlphaEvery` steps, and the scene needs about
    /// 3k steps to re-converge afterwards. The last reset must therefore land
    /// at least 3k steps before `totalSteps` — 100 × 30 = 3000 puts the final
    /// reset at 12k of 15k. Exporting closer to a reset ships half-recovered
    /// opacities: glowing haze that the cleaner's alpha thresholds can't
    /// separate from real surfaces.
    /// SH degree 2 over 3: the top band is visually negligible but nearly
    /// doubles per-splat optimizer state; degree 2 funds denser geometry
    /// (densifyGradThresh at msplat stock 0.0002) within the same memory.
    public init(
        totalSteps: Int = 15_000,
        sphericalHarmonicsDegree: Int = 2,
        exportInterval: Int = 3_000,
        keepCoordinateSystem: Bool = true,
        refineEvery: Int = 100,
        warmupLength: Int = 500,
        resetAlphaEvery: Int = 30,
        densifyGradThresh: Float = 0.0002,
        densifySizeThresh: Float = 0.01,
        stopScreenSizeAt: Int = 4_000,
        splitScreenSize: Float = 0.05
    ) {
        self.totalSteps = totalSteps
        self.sphericalHarmonicsDegree = sphericalHarmonicsDegree
        self.exportInterval = exportInterval
        self.keepCoordinateSystem = keepCoordinateSystem
        self.refineEvery = refineEvery
        self.warmupLength = warmupLength
        self.resetAlphaEvery = resetAlphaEvery
        self.densifyGradThresh = densifyGradThresh
        self.densifySizeThresh = densifySizeThresh
        self.stopScreenSizeAt = stopScreenSizeAt
        self.splitScreenSize = splitScreenSize
    }
}

public struct TrainingProgress: Sendable, Equatable {
    public let completedSteps: Int
    public let totalSteps: Int

    public var fraction: Double {
        Double(completedSteps) / Double(totalSteps)
    }

    public init(completedSteps: Int, totalSteps: Int) {
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
    }
}

public struct TrainingResult: Sendable, Equatable {
    public let plyURL: URL
    public let bytes: Int
    public let gaussianCount: Int
    public let steps: Int
    public let wallTimeSeconds: Double
    public let peakResidentBytes: UInt64?

    public init(
        plyURL: URL,
        bytes: Int,
        gaussianCount: Int,
        steps: Int,
        wallTimeSeconds: Double = 0,
        peakResidentBytes: UInt64? = nil
    ) {
        self.plyURL = plyURL
        self.bytes = bytes
        self.gaussianCount = gaussianCount
        self.steps = steps
        self.wallTimeSeconds = wallTimeSeconds
        self.peakResidentBytes = peakResidentBytes
    }
}

public protocol TrainerBackend: Sendable {
    func train(
        datasetURL: URL,
        outputURL: URL,
        options: TrainingOptions,
        progress: (@Sendable (TrainingProgress) async -> Void)?
    ) async throws -> TrainingResult
}
