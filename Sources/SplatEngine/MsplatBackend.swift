import Darwin
import Foundation
import PoseCore

public actor MsplatBackend: TrainerBackend {
    public enum Error: LocalizedError {
        case executableMissing(URL)
        case metallibMissing(URL)
        case outputAlreadyExists(URL)
        case processFailed(Int32, String)
        case missingExport(URL)
        case invalidExport(URL)
        case emptyExport(URL)

        public var errorDescription: String? {
            switch self {
            case let .executableMissing(url):
                "The pinned msplat executable is missing at \(url.path)."
            case let .metallibMissing(url):
                "The pinned msplat shader library is missing at \(url.path)."
            case let .outputAlreadyExists(url):
                "The msplat training output already exists at \(url.path)."
            case let .processFailed(status, output):
                "msplat exited with status \(status): \(output)"
            case let .missingExport(url):
                "msplat did not create its final PLY at \(url.path)."
            case let .invalidExport(url):
                "msplat created an invalid PLY at \(url.path)."
            case let .emptyExport(url):
                "msplat exported zero Gaussians at \(url.path)."
            }
        }
    }

    private let runtime: MsplatRuntimeLocation
    private let progressPollInterval: Duration
    private nonisolated let processState = MsplatActiveProcessState()

    public init(
        runtime: MsplatRuntimeLocation,
        progressPollInterval: Duration = .seconds(1)
    ) {
        self.runtime = runtime
        self.progressPollInterval = progressPollInterval
    }

    public func train(
        datasetURL: URL,
        outputURL: URL,
        options: TrainingOptions = TrainingOptions(),
        progress: (@Sendable (TrainingProgress) async -> Void)? = nil
    ) async throws -> TrainingResult {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(
            atPath: runtime.executableURL.path
        ) else {
            throw Error.executableMissing(runtime.executableURL)
        }
        guard fileManager.fileExists(atPath: runtime.metallibURL.path) else {
            throw Error.metallibMissing(runtime.metallibURL)
        }
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw Error.outputAlreadyExists(outputURL)
        }
        try fileManager.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        defer {
            TrainerProcessRecovery.removeLease(from: outputURL)
        }
        let finalPLYURL = outputURL.appendingPathComponent("splat.ply")
        let startedAt = ContinuousClock.now
        let resourceSampler = ProcessResourceSampler()

        let process = Process()
        process.executableURL = runtime.executableURL
        process.currentDirectoryURL =
            runtime.executableURL.deletingLastPathComponent()
        process.arguments = MsplatArguments.make(
            datasetURL: datasetURL,
            outputPLYURL: finalPLYURL,
            options: options
        )
        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputCollector = MsplatOutputCollector()
        let errorCollector = MsplatOutputCollector()
        let progressEmitter = MsplatProgressEmitter(
            totalSteps: options.totalSteps,
            handler: progress
        )
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            outputCollector.append(data)
            Task { await progressEmitter.ingest(data) }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            errorCollector.append(data)
            Task { await progressEmitter.ingest(data) }
        }
        process.standardOutput = standardOutput
        process.standardError = standardError
        let box = MsplatProcessBox(process)
        let (terminations, continuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { _ in
            continuation.yield(box.process.terminationStatus)
            continuation.finish()
        }
        processState.set(process)
        defer { processState.clear() }

        return try await withTaskCancellationHandler {
            let processMonitor = Task {
                while !Task.isCancelled {
                    if process.isRunning {
                        resourceSampler.sample(
                            processIdentifier: process.processIdentifier
                        )
                    }
                    if progress != nil,
                       let step = Self.latestCheckpointStep(
                        in: outputURL
                    ) {
                        await progressEmitter.emit(step: step)
                    }
                    try? await Task.sleep(for: progressPollInterval)
                }
            }
            let status: Int32
            do {
                try Task.checkCancellation()
                try process.run()
                do {
                    try TrainerProcessLease.write(
                        process: process,
                        to: outputURL
                    )
                } catch {
                    process.terminate()
                    _ = await terminations.first(where: { _ in true })
                    throw error
                }
                status = await terminations.first(where: { _ in true }) ?? -1
            } catch {
                processMonitor.cancel()
                _ = await processMonitor.result
                throw error
            }
            processMonitor.cancel()
            _ = await processMonitor.result
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            outputCollector.append(
                standardOutput.fileHandleForReading.readDataToEndOfFile()
            )
            errorCollector.append(
                standardError.fileHandleForReading.readDataToEndOfFile()
            )
            await progressEmitter.ingest(outputCollector.data)
            await progressEmitter.ingest(errorCollector.data)
            try Task.checkCancellation()
            guard status == 0 else {
                let diagnostic = String(
                    data: errorCollector.data + outputCollector.data,
                    encoding: .utf8
                ) ?? "No diagnostic output."
                throw Error.processFailed(status, diagnostic)
            }
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
            await progressEmitter.emit(step: options.totalSteps)
            let elapsed = startedAt.duration(to: .now)
            let wallTimeSeconds =
                Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            return TrainingResult(
                plyURL: finalPLYURL,
                bytes: bytes,
                gaussianCount: gaussianCount,
                steps: options.totalSteps,
                wallTimeSeconds: wallTimeSeconds,
                peakResidentBytes: resourceSampler.peakResidentBytes
            )
        } onCancel: {
            self.cancel()
        }
    }

    public nonisolated func cancel() {
        processState.cancel()
    }

    private nonisolated static func latestCheckpointStep(
        in outputURL: URL
    ) -> Int? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: outputURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return urls.compactMap { url -> Int? in
            let name = url.deletingPathExtension().lastPathComponent
            guard
                url.pathExtension.lowercased() == "ply",
                name.hasPrefix("splat_")
            else {
                return nil
            }
            return Int(name.dropFirst("splat_".count))
        }
        .max()
    }
}

private final class ProcessResourceSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0

    var peakResidentBytes: UInt64? {
        lock.withLock { peak == 0 ? nil : peak }
    }

    func sample(processIdentifier: Int32) {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            let rawPointer = UnsafeMutableRawPointer(pointer)
                .assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(
                processIdentifier,
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

private final class MsplatProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class MsplatActiveProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.withLock {
            self.process = process
        }
    }

    func clear() {
        lock.withLock {
            process = nil
        }
    }

    func cancel() {
        lock.withLock {
            guard let process, process.isRunning else {
                return
            }
            process.terminate()
        }
    }
}

private final class MsplatOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.withLock { storage }
    }

    func append(_ data: Data) {
        lock.withLock {
            storage.append(data)
        }
    }
}

private actor MsplatProgressEmitter {
    private let totalSteps: Int
    private let handler: (@Sendable (TrainingProgress) async -> Void)?
    private var highestStep = 0

    init(
        totalSteps: Int,
        handler: (@Sendable (TrainingProgress) async -> Void)?
    ) {
        self.totalSteps = totalSteps
        self.handler = handler
    }

    func ingest(_ data: Data) async {
        guard let handler, let text = String(data: data, encoding: .utf8) else {
            return
        }
        for line in text.split(whereSeparator: { $0.isNewline || $0 == "\r" }) {
            guard
                let step = MsplatProgressParser.step(in: String(line)),
                step > highestStep
            else {
                continue
            }
            highestStep = step
            await handler(TrainingProgress(
                completedSteps: min(step, totalSteps),
                totalSteps: totalSteps
            ))
        }
    }

    func emit(step: Int) async {
        guard let handler, step > highestStep else {
            return
        }
        highestStep = step
        await handler(TrainingProgress(
            completedSteps: min(step, totalSteps),
            totalSteps: totalSteps
        ))
    }
}
