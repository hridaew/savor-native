import AppKit
import SplatEngine
import SwiftUI
import UniformTypeIdentifiers

/// Which pass of the capture the viewer is showing. `custom` reveals a live
/// scrubber that melts the raw scene toward the isolated subject.
enum SplatViewMode: Hashable {
    case cleaned
    case custom
    case unfiltered
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var audio = CaptureAudioController()
    @StateObject private var viewerProxy = SplatViewerProxy()
    @State private var isImportingVideo = false
    @State private var viewerStatus: ViewerStatus = .idle
    @State private var viewerResetToken = 0
    @State private var viewerAutoRotate = false
    @State private var viewerVerticalAxis: ViewerVerticalAxis = .yUp
    @State private var viewMode: SplatViewMode = .cleaned
    @State private var cleanAmount = 0.5
    @State private var captureToDelete: CaptureRecord?
    @State private var isShowingTips = false
    @State private var videoExportProgress: Double?
    @State private var videoExportTask: Task<Void, Never>?
    private let cliSplatURL: URL?

    init() {
        cliSplatURL = CommandLine.arguments
            .dropFirst()
            .first
            .map(URL.init(fileURLWithPath:))
            .flatMap { url in
                ["ply", "spz", "splat"].contains(
                    url.pathExtension.lowercased()
                ) ? url : nil
            }
    }

    var body: some View {
        Group {
            if let standalone = cliSplatURL ?? model.standaloneSampleURL {
                standaloneViewer(
                    standalone,
                    isSample: model.standaloneSampleURL != nil
                        && cliSplatURL == nil
                )
            } else {
                captureBrowser
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .fileImporter(
            isPresented: $isImportingVideo,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: false,
            onCompletion: selectVideo
        )
        .alert(
            "Savor Native",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            ),
            actions: {
                Button("OK") {
                    model.alertMessage = nil
                }
            },
            message: {
                Text(model.alertMessage ?? "")
            }
        )
    }

    // MARK: - Browser

    private var captureBrowser: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            captureDetail
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let videoURL = urls.first(where: {
                UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie)
                    == true
            }) else {
                return false
            }
            model.importVideo(videoURL)
            return true
        }
        .onChange(of: model.selectedCaptureID) { _, _ in
            viewMode = .cleaned
            viewerResetToken += 1
            videoExportTask?.cancel()
            audio.stop()
        }
        .confirmationDialog(
            "Delete “\(captureToDelete?.sourceFilename ?? "capture")”?",
            isPresented: Binding(
                get: { captureToDelete != nil },
                set: { if !$0 { captureToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: captureToDelete
        ) { capture in
            Button("Delete Capture", role: .destructive) {
                model.deleteCapture(capture)
                captureToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                captureToDelete = nil
            }
        } message: { _ in
            Text(
                "The saved video and generated splat are removed from "
                    + "Savor's library. This can't be undone."
            )
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SAVOR")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2.6)
                Spacer()
                Button {
                    isImportingVideo = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New capture")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            if model.captures.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 24, weight: .light))
                    Text("No captures yet")
                        .font(.callout.weight(.medium))
                    Text("Drop a video to begin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open sample") {
                        model.openBundledSample()
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.secondary)
            } else {
                List(
                    model.captures,
                    selection: $model.selectedCaptureID
                ) { capture in
                    CaptureRow(capture: capture)
                        .tag(capture.id)
                        .contextMenu {
                            if capture.state == .completed,
                               let splatURL = model.splatURL(for: capture) {
                                Button("Reveal Splat in Finder") {
                                    NSWorkspace.shared
                                        .activateFileViewerSelecting([splatURL])
                                }
                            }
                            if !capture.state.isInFlight {
                                Button("Start Over from Saved Video") {
                                    model.retry(capture)
                                }
                                Divider()
                                Button("Delete Capture…", role: .destructive) {
                                    captureToDelete = capture
                                }
                            }
                        }
                }
                .listStyle(.sidebar)
                .onDeleteCommand {
                    if let capture = model.selectedCapture,
                       !capture.state.isInFlight {
                        captureToDelete = capture
                    }
                }
            }

            Divider()

            Button {
                isImportingVideo = true
            } label: {
                Label("New capture", systemImage: "video.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .padding(14)
        }
    }

    @ViewBuilder
    private var captureDetail: some View {
        if let capture = model.selectedCapture {
            switch capture.state {
            case .completed:
                completedDetail(capture)
            case .failed, .cancelled, .interrupted:
                failureView(
                    capture,
                    message: capture.errorMessage
                        ?? "This capture did not finish."
                )
            case .queued, .extractingFrames, .estimatingPoses,
                 .writingDataset, .training, .postprocessing:
                processingView(capture)
            }
        } else {
            dropView
        }
    }

    @ViewBuilder
    private func completedDetail(_ capture: CaptureRecord) -> some View {
        let cleanedURL = model.splatURL(for: capture)
        let rawURL = model.splatURL(for: capture, unfiltered: true)
        let activeURL: URL? = switch viewMode {
        case .cleaned:
            cleanedURL ?? rawURL
        case .custom, .unfiltered:
            rawURL ?? cleanedURL
        }
        if let activeURL {
            completedViewer(
                url: activeURL,
                capture: capture,
                hasRawSplat: rawURL != nil
            )
        } else {
            failureView(capture, message: "The finished splat is missing.")
        }
    }

    // MARK: - Empty state

    private var dropView: some View {
        ZStack {
            atmosphericBackground
            VStack(spacing: 26) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.09), lineWidth: 1)
                        .frame(width: 208, height: 208)
                    Circle()
                        .fill(.white.opacity(0.035))
                        .frame(width: 144, height: 144)
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 48, weight: .thin))
                }
                VStack(spacing: 9) {
                    Text("Turn a video into a scene.")
                        .font(.system(size: 34, weight: .medium, design: .serif))
                    Text("Drop an orbit video here, or choose one from disk.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Button("Choose video") {
                    isImportingVideo = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.white)
                .foregroundStyle(.black)
                HStack(spacing: 12) {
                    Button("Open sample splat") {
                        model.openBundledSample()
                    }
                    Button("Filming tips") {
                        isShowingTips = true
                    }
                    .popover(isPresented: $isShowingTips) {
                        CaptureTipsView()
                    }
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .foregroundStyle(.white)
        }
    }

    // MARK: - Processing

    private func processingView(_ capture: CaptureRecord) -> some View {
        let progress = model.runningCaptureID == capture.id
            ? model.pipelineProgress
            : nil
        let previewURL = model.runningCaptureID == capture.id
            ? model.instantPreviewURL
            : model.previewURL(for: capture)
        let isCheckpoint = previewURL?.lastPathComponent
            .hasPrefix("splat_") == true
        return ZStack {
            if let previewURL {
                SplatMetalView(
                    url: previewURL,
                    status: $viewerStatus,
                    resetToken: viewerResetToken,
                    autoRotate: true,
                    verticalAxis: .yDown
                )
                .ignoresSafeArea()
            } else {
                atmosphericBackground
                VStack(spacing: 12) {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 42, weight: .thin))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("First preview lands after the first "
                        + "training checkpoint.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            VStack {
                HStack {
                    if previewURL != nil {
                        Text(isCheckpoint ? "TRAINING PREVIEW — LIVE"
                            : "INSTANT PREVIEW")
                            .font(.system(
                                size: 10,
                                weight: .bold,
                                design: .monospaced
                            ))
                            .tracking(2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                isCheckpoint
                                    ? AnyShapeStyle(.green.opacity(0.85))
                                    : AnyShapeStyle(.orange.opacity(0.85)),
                                in: Capsule()
                            )
                            .foregroundStyle(.black)
                            .transition(.opacity)
                    }
                    Spacer()
                }
                Spacer()
                processingDebugBar(capture, progress: progress)
            }
            .padding(16)
        }
        .animation(.easeOut(duration: 0.25), value: previewURL)
    }

    /// Bottom console: what the pipeline is doing right now, verbatim,
    /// with the stage rail and a thin determinate bar.
    private func processingDebugBar(
        _ capture: CaptureRecord,
        progress: PipelineProgress?
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(stageTitle(progress?.stage, fallback: capture.state))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Int(((progress?.fraction ?? 0) * 100).rounded()))%")
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.65))
                if model.runningCaptureID == capture.id {
                    Button("Cancel", role: .destructive) {
                        model.cancelCurrentCapture()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.white)
                }
            }

            ProgressView(value: progress?.fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(.white)
                .controlSize(.small)

            HStack(alignment: .center, spacing: 14) {
                Text(progress?.detail ?? capture.state.displayName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                StageRail(current: progress?.stage)
                    .frame(width: 300)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            .black.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .frame(maxWidth: 760)
        .animation(.easeOut(duration: 0.2), value: progress?.detail)
    }

    // MARK: - Failure

    private func failureView(
        _ capture: CaptureRecord,
        message: String
    ) -> some View {
        ZStack {
            Color(red: 0.055, green: 0.06, blue: 0.07)
            VStack(spacing: 18) {
                Image(systemName: capture.state == .interrupted
                    ? "pause.circle"
                    : "exclamationmark.circle")
                    .font(.system(size: 45, weight: .thin))
                Text(capture.state == .interrupted
                    ? "Capture interrupted"
                    : "Capture incomplete")
                    .font(.system(size: 30, weight: .medium, design: .serif))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                HStack(spacing: 12) {
                    Button("Start over from saved video") {
                        model.retry(capture)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    Button("Delete capture…", role: .destructive) {
                        captureToDelete = capture
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(.top, 8)
            }
            .padding()
            .foregroundStyle(.white)
        }
    }

    // MARK: - Completed viewer

    private func completedViewer(
        url: URL,
        capture: CaptureRecord,
        hasRawSplat: Bool
    ) -> some View {
        ZStack {
            SplatMetalView(
                url: url,
                status: $viewerStatus,
                resetToken: viewerResetToken,
                autoRotate: viewerAutoRotate,
                verticalAxis: viewerVerticalAxis,
                customCleanFraction: viewMode == .custom
                    ? Float(cleanAmount)
                    : nil,
                proxy: viewerProxy
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                viewerTopBar(capture, hasRawSplat: hasRawSplat)
                if viewMode == .custom {
                    cleanupSliderBar
                        .transition(
                            .move(edge: .top).combined(with: .opacity)
                        )
                }
                Spacer()
                if let progress = videoExportProgress {
                    exportProgressCard(progress)
                        .transition(.opacity)
                }
                viewerControls(capture)
            }
            .padding(16)
            .animation(.easeOut(duration: 0.22), value: viewMode)
            .animation(
                .easeOut(duration: 0.2),
                value: videoExportProgress == nil
            )
        }
        .task(id: capture.id) {
            audio.prepare(videoURL: model.sourceVideoURL(for: capture))
        }
    }

    private func viewerTopBar(
        _ capture: CaptureRecord,
        hasRawSplat: Bool
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(capture.sourceFilename)
                    .font(.headline)
                    .lineLimit(1)
                viewerStatusLabel
                    .font(.caption)
            }
            .foregroundStyle(.white)

            Spacer()

            if hasRawSplat {
                Picker("Splat view", selection: $viewMode) {
                    Text("Cleaned").tag(SplatViewMode.cleaned)
                    Text("Custom").tag(SplatViewMode.custom)
                    Text("Unfiltered").tag(SplatViewMode.unfiltered)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .labelsHidden()
                .help(
                    "Cleaned is the isolated subject. Unfiltered is the raw "
                        + "training splat. Custom cleans live as you drag."
                )
                .onChange(of: viewMode) { _, _ in
                    viewerResetToken += 1
                }
            }

            Menu {
                Button("Image (PNG)…") {
                    exportImage(capture)
                }
                Button("Orbit Video (MP4)…") {
                    exportOrbitVideo(capture)
                }
                Divider()
                Button("Splat (PLY)…") {
                    presentSavePanel(
                        suggestedName: viewMode == .cleaned
                            ? "scene-hq.ply"
                            : "splat.ply",
                        copying: model.splatURL(
                            for: capture,
                            unfiltered: viewMode != .cleaned
                        ) ?? model.splatURL(for: capture)
                    )
                }
                if let meshURL = model.meshURL(for: capture) {
                    Button("Mesh (USDZ)…") {
                        presentSavePanel(
                            suggestedName: "mesh.usdz",
                            copying: meshURL
                        )
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .disabled(videoExportProgress != nil)
            .tint(.white)

            Button {
                isShowingTips = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .help("What kinds of videos work best")
            .popover(isPresented: $isShowingTips) {
                CaptureTipsView()
            }

            Button {
                isImportingVideo = true
            } label: {
                Label("New capture", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            .black.opacity(0.58),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }

    /// Revealed under the top bar in Custom mode: scrubs from the raw scene
    /// (left) to a tightly isolated core (right), rebuilding the splat live.
    private var cleanupSliderBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.white.opacity(0.7))
                .font(.system(size: 12))
            Text("RAW")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.5))
            Slider(value: $cleanAmount, in: 0...1)
                .controlSize(.small)
                .tint(.white)
            Text("CLEAN")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.5))
            if case let .ready(pointCount) = viewerStatus {
                Text("\(pointCount.formatted()) kept")
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 110, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            .black.opacity(0.58),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: 560)
    }

    private func exportProgressCard(_ progress: Double) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 220)
            Text("Rendering orbit \(Int((progress * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
            Button("Cancel", role: .cancel) {
                videoExportTask?.cancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            .black.opacity(0.65),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }

    // MARK: - Standalone viewer

    private func standaloneViewer(
        _ url: URL,
        isSample: Bool
    ) -> some View {
        ZStack {
            SplatMetalView(
                url: url,
                status: $viewerStatus,
                resetToken: viewerResetToken,
                autoRotate: viewerAutoRotate,
                verticalAxis: isSample ? .yUp : viewerVerticalAxis,
                proxy: viewerProxy
            )
                .ignoresSafeArea()
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isSample ? "Sample splat" : url.lastPathComponent)
                            .font(.headline)
                        viewerStatusLabel
                            .font(.caption)
                    }
                    Spacer()
                    Button {
                        exportImage(nil)
                    } label: {
                        Label("Image", systemImage: "camera")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    if isSample {
                        Button("Back") {
                            model.standaloneSampleURL = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    .black.opacity(0.58),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
                Spacer()
                viewerControls(nil)
            }
            .padding(16)
        }
    }

    // MARK: - Exports

    private func exportImage(_ capture: CaptureRecord?) {
        let baseName = capture.map {
            ($0.sourceFilename as NSString).deletingPathExtension
        } ?? "splat"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(baseName).png"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else {
                return
            }
            Task { @MainActor in
                do {
                    guard let renderer = viewerProxy.renderer,
                          renderer.isSceneLoaded else {
                        throw ExportError.sceneNotLoaded
                    }
                    let image = try await renderer.snapshotImage()
                    guard let imageDestination =
                        CGImageDestinationCreateWithURL(
                            destination as CFURL,
                            UTType.png.identifier as CFString,
                            1,
                            nil
                        )
                    else {
                        throw ExportError.imageEncodingFailed
                    }
                    CGImageDestinationAddImage(imageDestination, image, nil)
                    guard CGImageDestinationFinalize(imageDestination) else {
                        throw ExportError.imageEncodingFailed
                    }
                    NSWorkspace.shared
                        .activateFileViewerSelecting([destination])
                } catch {
                    model.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func exportOrbitVideo(_ capture: CaptureRecord) {
        let baseName = (capture.sourceFilename as NSString)
            .deletingPathExtension
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(baseName)-orbit.mp4"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else {
                return
            }
            videoExportTask = Task { @MainActor in
                videoExportProgress = 0
                defer {
                    videoExportProgress = nil
                    videoExportTask = nil
                }
                do {
                    guard let renderer = viewerProxy.renderer,
                          renderer.isSceneLoaded else {
                        throw ExportError.sceneNotLoaded
                    }
                    try await renderer.exportOrbitVideo(
                        to: destination,
                        progress: { videoExportProgress = $0 }
                    )
                    NSSound(named: "Glass")?.play()
                    NSWorkspace.shared
                        .activateFileViewerSelecting([destination])
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: destination)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    model.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func presentSavePanel(suggestedName: String, copying source: URL?) {
        guard let source else {
            model.alertMessage = "Nothing is available to export."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else {
                return
            }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Viewer chrome

    private func viewerControls(_ capture: CaptureRecord?) -> some View {
        HStack(spacing: 10) {
            Button {
                viewerResetToken += 1
            } label: {
                Label("Reset", systemImage: "viewfinder")
            }
            Button {
                viewerAutoRotate.toggle()
            } label: {
                Label(
                    viewerAutoRotate ? "Pause" : "Rotate",
                    systemImage: viewerAutoRotate ? "pause.fill" : "play.fill"
                )
            }
            Button {
                viewerVerticalAxis = viewerVerticalAxis == .yUp
                    ? .yDown
                    : .yUp
                viewerResetToken += 1
            } label: {
                Label(
                    viewerVerticalAxis == .yUp ? "Y Up" : "Y Down",
                    systemImage: "arrow.up.and.down"
                )
            }

            if capture != nil {
                Divider()
                    .frame(height: 16)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        audio.isPlaying.toggle()
                    }
                } label: {
                    Label(
                        audio.isPlaying ? "Sound On" : "Sound",
                        systemImage: audio.isPlaying
                            ? "speaker.wave.2.fill"
                            : "speaker.slash"
                    )
                }
                .help("Loop the capture's original soundtrack")
                if audio.isPlaying {
                    Slider(value: $audio.volume, in: 0...1)
                        .controlSize(.mini)
                        .tint(.white)
                        .frame(width: 84)
                        .transition(
                            .move(edge: .leading).combined(with: .opacity)
                        )
                }
            }

            Text("LEFT DRAG ORBITS · RIGHT DRAG PANS · SCROLL ZOOMS · R RESETS")
                .font(.system(
                    size: 9,
                    weight: .medium,
                    design: .monospaced
                ))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.72))
                .padding(.leading, 4)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(
            Capsule().stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }

    @ViewBuilder
    private var viewerStatusLabel: some View {
        switch viewerStatus {
        case .idle:
            Text("Ready")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading…")
            }
            .foregroundStyle(.secondary)
        case let .ready(pointCount):
            Text("\(pointCount.formatted()) Gaussians")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case let .failed(message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    private var atmosphericBackground: some View {
        RadialGradient(
            colors: [
                Color(red: 0.15, green: 0.17, blue: 0.2),
                Color(red: 0.018, green: 0.021, blue: 0.03),
            ],
            center: .center,
            startRadius: 20,
            endRadius: 620
        )
        .ignoresSafeArea()
    }

    private func selectVideo(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            if let url = urls.first {
                model.importVideo(url)
            }
        case let .failure(error):
            model.alertMessage = error.localizedDescription
        }
    }

    private func stageTitle(
        _ stage: PipelineStage?,
        fallback: CaptureState
    ) -> String {
        switch stage {
        case .extractingFrames:
            "Extracting video frames"
        case .estimatingPoses:
            "Estimating camera motion"
        case .buildingPointCloud:
            "Building sparse geometry"
        case .writingDataset:
            "Preparing trainer dataset"
        case .training:
            "Training Gaussian field"
        case .postprocessing:
            "Cleaning and framing scene"
        case nil:
            fallback.displayName
        }
    }
}

private struct CaptureRow: View {
    let capture: CaptureRecord

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(capture.state.tint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(capture.sourceFilename)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(
                    capture.state.displayName
                        + " · "
                        + capture.createdAt.formatted(
                            .relative(presentation: .named)
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct StageRail: View {
    let current: PipelineStage?

    private let stages: [(PipelineStage, String)] = [
        (.extractingFrames, "FRAMES"),
        (.estimatingPoses, "POSES"),
        (.writingDataset, "DATASET"),
        (.training, "TRAIN"),
        (.postprocessing, "CLEAN"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, entry in
                VStack(spacing: 6) {
                    Circle()
                        .fill(color(for: entry.0))
                        .frame(width: 7, height: 7)
                    Text(entry.1)
                        .font(.system(
                            size: 8,
                            weight: .medium,
                            design: .monospaced
                        ))
                        .foregroundStyle(.white.opacity(0.55))
                }
                if index < stages.count - 1 {
                    Rectangle()
                        .fill(.white.opacity(0.15))
                        .frame(height: 1)
                }
            }
        }
    }

    private func color(for stage: PipelineStage) -> Color {
        guard let current else {
            return .white.opacity(0.18)
        }
        return order(stage) <= order(current) ? .white : .white.opacity(0.18)
    }

    private func order(_ stage: PipelineStage) -> Int {
        switch stage {
        case .extractingFrames:
            0
        case .estimatingPoses, .buildingPointCloud:
            1
        case .writingDataset:
            2
        case .training:
            3
        case .postprocessing:
            4
        }
    }
}

private extension CaptureState {
    var displayName: String {
        switch self {
        case .queued:
            "Queued"
        case .extractingFrames:
            "Extracting frames"
        case .estimatingPoses:
            "Estimating poses"
        case .writingDataset:
            "Preparing dataset"
        case .training:
            "Training"
        case .postprocessing:
            "Cleaning scene"
        case .completed:
            "Ready"
        case .cancelled:
            "Cancelled"
        case .interrupted:
            "Interrupted"
        case .failed:
            "Failed"
        }
    }

    var tint: Color {
        switch self {
        case .completed:
            .green
        case .failed, .cancelled:
            .red
        case .interrupted:
            .orange
        case .queued, .extractingFrames, .estimatingPoses, .writingDataset,
             .training, .postprocessing:
            .blue
        }
    }
}
