import Darwin
import Foundation
import Msplat
import PoseCore

public enum MsplatTrainingConfigMapper {
    public static func makeConfig(
        from options: TrainingOptions
    ) -> TrainingConfig {
        var config = TrainingConfig()
        config.iterations = Int32(options.totalSteps)
        config.shDegree = Int32(options.sphericalHarmonicsDegree)
        config.keepCrs = options.keepCoordinateSystem
        config.refineEvery = Int32(options.refineEvery)
        config.warmupLength = Int32(options.warmupLength)
        config.resetAlphaEvery = Int32(options.resetAlphaEvery)
        config.densifyGradThresh = options.densifyGradThresh
        config.densifySizeThresh = options.densifySizeThresh
        config.stopScreenSizeAt = Int32(options.stopScreenSizeAt)
        config.splitScreenSize = options.splitScreenSize
        // Leave numDownscales/downscaleFactor at the library defaults: the
        // CLI trains coarse-to-fine by default, and every quality bake ran
        // through the CLI — overriding to full-res-from-step-0 here made the
        // app's in-process training diverge from everything validated.
        return config
    }
}

public actor MsplatInProcessBackend: TrainerBackend {
    public enum Error: LocalizedError {
        case outputAlreadyExists(URL)
        case missingExport(URL)
        case invalidExport(URL)
        case emptyDataset(URL)
        case emptyExport(URL)

        public var errorDescription: String? {
            switch self {
            case let .outputAlreadyExists(url):
                "The msplat training output already exists at \(url.path)."
            case let .missingExport(url):
                "msplat did not create its final PLY at \(url.path)."
            case let .invalidExport(url):
                "msplat created an invalid PLY at \(url.path)."
            case let .emptyDataset(url):
                "msplat loaded zero training cameras from \(url.path)."
            case let .emptyExport(url):
                "msplat exported zero Gaussians at \(url.path)."
            }
        }
    }

    public init() {}

    public func train(
        datasetURL: URL,
        outputURL: URL,
        options: TrainingOptions = TrainingOptions(),
        progress: (@Sendable (TrainingProgress) async -> Void)? = nil
    ) async throws -> TrainingResult {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw Error.outputAlreadyExists(outputURL)
        }
        try fileManager.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        let finalPLYURL = outputURL.appendingPathComponent("splat.ply")
        let startedAt = ContinuousClock.now
        let resourceSampler = CurrentProcessResourceSampler()

        let dataset = GaussianDataset(
            path: datasetURL.path,
            downscaleFactor: 1.0
        )
        guard dataset.numTrain > 0 else {
            throw Error.emptyDataset(datasetURL)
        }
        let config = MsplatTrainingConfigMapper.makeConfig(from: options)
        let trainer = GaussianTrainer(dataset: dataset, config: config)
        defer {
            msplatCleanup()
        }

        var highestReportedStep = 0
        let totalSteps = options.totalSteps
        while trainer.iteration < totalSteps {
            try Task.checkCancellation()
            let stats = trainer.step()
            resourceSampler.sample()
            let step = max(stats.iteration, trainer.iteration)
            if let progress,
               step > highestReportedStep,
               step == totalSteps
                || step % 100 == 0
                || (options.exportInterval > 0
                    && step % options.exportInterval == 0) {
                highestReportedStep = step
                await progress(TrainingProgress(
                    completedSteps: min(step, totalSteps),
                    totalSteps: totalSteps
                ))
            }
            if options.exportInterval > 0,
               step > 0,
               step % options.exportInterval == 0,
               step < totalSteps {
                let checkpointURL = outputURL.appendingPathComponent(
                    "splat_\(step).ply"
                )
                if !fileManager.fileExists(atPath: checkpointURL.path) {
                    trainer.exportPly(to: checkpointURL.path)
                }
            }
        }

        try Task.checkCancellation()
        trainer.exportPly(to: finalPLYURL.path)
        guard fileManager.fileExists(atPath: finalPLYURL.path) else {
            throw Error.missingExport(finalPLYURL)
        }
        let handle = try FileHandle(forReadingFrom: finalPLYURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4_096) ?? Data()
        let gaussianCount: Int
        do {
            gaussianCount = try PLYHeaderReader.vertexCount(in: header)
        } catch {
            throw Error.invalidExport(finalPLYURL)
        }
        guard gaussianCount > 0 else {
            throw Error.emptyExport(finalPLYURL)
        }
        let attributes = try fileManager.attributesOfItem(
            atPath: finalPLYURL.path
        )
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if let progress {
            await progress(TrainingProgress(
                completedSteps: totalSteps,
                totalSteps: totalSteps
            ))
        }
        let elapsed = startedAt.duration(to: .now)
        let wallTimeSeconds =
            Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        return TrainingResult(
            plyURL: finalPLYURL,
            bytes: bytes,
            gaussianCount: gaussianCount,
            steps: totalSteps,
            wallTimeSeconds: wallTimeSeconds,
            peakResidentBytes: resourceSampler.peakResidentBytes
        )
    }
}

private final class CurrentProcessResourceSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0

    var peakResidentBytes: UInt64? {
        lock.withLock { peak == 0 ? nil : peak }
    }

    func sample() {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            let rawPointer = UnsafeMutableRawPointer(pointer)
                .assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(
                getpid(),
                RUSAGE_INFO_V2,
                rawPointer
            )
        }
        guard status == 0 else {
            return
        }
        lock.withLock {
            peak = max(peak, info.ri_phys_footprint)
        }
    }
}
