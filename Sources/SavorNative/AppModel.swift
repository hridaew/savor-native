import AppKit
import Combine
import Foundation
import SplatEngine

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var captures: [CaptureRecord] = []
    @Published var selectedCaptureID: UUID?
    @Published private(set) var runningCaptureID: UUID?
    @Published private(set) var pipelineProgress: PipelineProgress?
    @Published private(set) var instantPreviewURL: URL?
    @Published var alertMessage: String?
    @Published var standaloneSampleURL: URL?

    private let repository: CaptureRepository
    private let rootLock: CaptureRootLock?
    private var pipelineTask: Task<Void, Never>?
    private var previewPollTask: Task<Void, Never>?
    private var admission = CaptureAdmission()

    init(repository: CaptureRepository = CaptureRepository(
        rootURL: AppModel.defaultCapturesURL
    )) {
        self.repository = repository
        do {
            rootLock = try CaptureRootLock(rootURL: repository.rootURL)
        } catch {
            rootLock = nil
            alertMessage = "Savor Native is already processing captures in "
                + "another app instance."
            return
        }
        Task {
            await reload()
            if let startupVideoURL = Self.startupVideoURL {
                importVideo(startupVideoURL)
            }
        }
    }

    var selectedCapture: CaptureRecord? {
        captures.first { $0.id == selectedCaptureID }
    }

    func importVideo(_ url: URL) {
        guard rootLock != nil else {
            alertMessage = "Capture processing is owned by another app instance."
            return
        }
        guard #available(macOS 26.0, *) else {
            alertMessage = "Savor Native capture requires macOS 26 or newer."
            return
        }
        guard admission.reserve() else {
            alertMessage = "Finish or cancel the current capture first."
            return
        }
        pipelineTask = Task { [weak self] in
            await self?.runCapture(from: url)
        }
    }

    func retry(_ record: CaptureRecord) {
        importVideo(repository.sourceVideoURL(for: record))
    }

    func cancelCurrentCapture() {
        pipelineTask?.cancel()
    }

    /// Removes the capture and everything on disk under its workspace.
    /// The running capture must be cancelled first.
    func deleteCapture(_ record: CaptureRecord) {
        guard runningCaptureID != record.id else {
            alertMessage = "Cancel this capture before deleting it."
            return
        }
        Task {
            do {
                try await repository.delete(record.id)
                captures.removeAll { $0.id == record.id }
                if selectedCaptureID == record.id {
                    selectedCaptureID = captures.first?.id
                }
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func splatURL(
        for record: CaptureRecord,
        unfiltered: Bool = false
    ) -> URL? {
        guard let relativePath = record.activeSplatRelativePath(
            unfiltered: unfiltered
        ) else {
            return nil
        }
        let url = repository.workspaceURL(for: record.id)
            .appendingPathComponent(relativePath)
        if unfiltered {
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return url
    }

    func hasUnfilteredSplat(for record: CaptureRecord) -> Bool {
        splatURL(for: record, unfiltered: true) != nil
    }

    func sourceVideoURL(for record: CaptureRecord) -> URL {
        repository.sourceVideoURL(for: record)
    }

    func meshURL(for record: CaptureRecord) -> URL? {
        let url = repository.workspaceURL(for: record.id)
            .appendingPathComponent("output/mesh.usdz")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func previewURL(for record: CaptureRecord) -> URL? {
        let url = repository.workspaceURL(for: record.id)
            .appendingPathComponent("output/sharp-preview.ply")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func openBundledSample() {
        guard let url = Bundle.module.url(
            forResource: "scene-hq",
            withExtension: "ply",
            subdirectory: "Samples"
        ) else {
            alertMessage = "Bundled sample splat is missing."
            return
        }
        standaloneSampleURL = url
    }

    func exportSplat(
        for record: CaptureRecord,
        to destinationURL: URL,
        unfiltered: Bool = false
    ) throws {
        guard let source = splatURL(for: record, unfiltered: unfiltered) else {
            throw AppModelError.exportUnavailable
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: source, to: destinationURL)
    }

    func exportMesh(
        for record: CaptureRecord,
        to destinationURL: URL
    ) throws {
        guard let source = meshURL(for: record) else {
            throw AppModelError.exportUnavailable
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: source, to: destinationURL)
    }

    private func reload() async {
        do {
            captures = try await repository.loadRecoveringInterrupted()
            do {
                captures = try await repository
                    .migrateLegacyCompletedCaptures()
            } catch {
                alertMessage = "A legacy capture could not be cleaned: "
                    + error.localizedDescription
            }
            if selectedCaptureID == nil {
                selectedCaptureID = captures.first?.id
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    @available(macOS 26.0, *)
    private func runCapture(from sourceURL: URL) async {
        var record: CaptureRecord?
        do {
            let created = try await repository.createCapture(from: sourceURL)
            record = created
            captures.insert(created, at: 0)
            selectedCaptureID = created.id
            runningCaptureID = created.id
            pipelineProgress = PipelineProgress(
                stage: .extractingFrames,
                fraction: 0
            )

            let trainer: any TrainerBackend
            do {
                trainer = try MsplatTrainerFactory.make()
            } catch {
                throw AppModelError.msplatUnavailable
            }
            let runner = PipelineRunner(trainer: trainer)
            let workspace = repository.workspaceURL(for: created.id)
            startPreviewPolling(workspaceURL: workspace, captureID: created.id)
            let result = try await runner.run(
                videoURL: repository.sourceVideoURL(for: created),
                workspaceURL: workspace,
                progress: { [weak self] progress in
                    await self?.receive(progress, for: created.id)
                }
            )
            try Task.checkCancellation()
            let sceneRelativePath = "output/\(result.sceneURL.lastPathComponent)"
            let rawRelativePath =
                "training/\(result.training.plyURL.lastPathComponent)"
            let completed = try await repository.transition(
                created.id,
                to: .completed,
                splatRelativePath: sceneRelativePath,
                rawSplatRelativePath: rawRelativePath,
                cleaning: CaptureCleaningSummary(result.cleaning)
            )
            replace(completed)
            NSSound(named: "Glass")?.play()
        } catch is CancellationError {
            if let record {
                await transitionAfterFailure(
                    record.id,
                    state: .cancelled,
                    message: "Capture cancelled."
                )
            }
        } catch {
            if let record {
                await transitionAfterFailure(
                    record.id,
                    state: .failed,
                    message: error.localizedDescription
                )
            } else {
                alertMessage = error.localizedDescription
            }
        }

        runningCaptureID = nil
        pipelineProgress = nil
        pipelineTask = nil
        previewPollTask?.cancel()
        previewPollTask = nil
        instantPreviewURL = nil
        admission.release()
    }

    /// Keeps `instantPreviewURL` pointed at the best preview available while
    /// the pipeline runs: first the SHARP single-image preview, then each
    /// msplat training checkpoint as it lands — so the processing screen
    /// shows the actual splat refining live.
    private func startPreviewPolling(workspaceURL: URL, captureID: UUID) {
        previewPollTask?.cancel()
        let sharpURL = workspaceURL
            .appendingPathComponent("output/sharp-preview.ply")
        let trainingURL = workspaceURL
            .appendingPathComponent("training", isDirectory: true)
        previewPollTask = Task { [weak self] in
            // A checkpoint is published only after its size holds steady
            // across two polls, so a half-written PLY is never loaded.
            var pendingURL: URL?
            var pendingSize: Int64 = -1
            while !Task.isCancelled {
                let candidate = Self.newestCheckpointPLY(in: trainingURL)
                    ?? (FileManager.default.fileExists(atPath: sharpURL.path)
                        ? sharpURL
                        : nil)
                if let candidate {
                    let size = (try? FileManager.default
                        .attributesOfItem(atPath: candidate.path)[.size]
                        as? Int64) ?? -1
                    if candidate == pendingURL, size == pendingSize, size > 0 {
                        guard let self, self.runningCaptureID == captureID
                        else {
                            return
                        }
                        if self.instantPreviewURL != candidate {
                            self.instantPreviewURL = candidate
                        }
                    }
                    pendingURL = candidate
                    pendingSize = size
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Newest `splat_<step>.ply` checkpoint the trainer has exported.
    private static func newestCheckpointPLY(in trainingURL: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: trainingURL.path
        ) else {
            return nil
        }
        let best = names.compactMap { name -> (step: Int, name: String)? in
            guard name.hasPrefix("splat_"), name.hasSuffix(".ply") else {
                return nil
            }
            let digits = name.dropFirst("splat_".count).dropLast(".ply".count)
            guard let step = Int(digits) else {
                return nil
            }
            return (step, name)
        }
        .max { $0.step < $1.step }
        guard let best else {
            return nil
        }
        return trainingURL.appendingPathComponent(best.name)
    }

    private func receive(
        _ progress: PipelineProgress,
        for id: UUID
    ) async {
        guard runningCaptureID == id else {
            return
        }
        pipelineProgress = progress
        let state: CaptureState
        switch progress.stage {
        case .extractingFrames:
            state = .extractingFrames
        case .estimatingPoses, .buildingPointCloud:
            state = .estimatingPoses
        case .writingDataset:
            state = .writingDataset
        case .training:
            state = .training
        case .postprocessing:
            state = .postprocessing
        }
        guard captures.first(where: { $0.id == id })?.state != state else {
            return
        }
        do {
            replace(try await repository.transition(id, to: state))
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func transitionAfterFailure(
        _ id: UUID,
        state: CaptureState,
        message: String
    ) async {
        do {
            replace(try await repository.transition(
                id,
                to: state,
                errorMessage: message
            ))
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func replace(_ record: CaptureRecord) {
        guard let index = captures.firstIndex(where: { $0.id == record.id }) else {
            captures.insert(record, at: 0)
            return
        }
        captures[index] = record
    }

    private static var defaultCapturesURL: URL {
        let fileManager = FileManager.default
        let applicationSupport = (
            try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        ) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("SavorNative", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
    }

    private static var startupVideoURL: URL? {
        guard let path = CommandLine.arguments.dropFirst().first else {
            return nil
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
            ? url
            : nil
    }
}

private enum AppModelError: LocalizedError {
    case msplatUnavailable
    case exportUnavailable

    var errorDescription: String? {
        switch self {
        case .msplatUnavailable:
            "The msplat trainer could not be started "
                + "(in-process or CLI recovery)."
        case .exportUnavailable:
            "Nothing is available to export for this capture."
        }
    }
}
