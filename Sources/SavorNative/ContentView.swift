import AppKit
import SplatEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isImportingVideo = false
    @State private var viewerStatus: ViewerStatus = .idle
    @State private var viewerResetToken = 0
    @State private var viewerAutoRotate = false
    @State private var viewerVerticalAxis: ViewerVerticalAxis = .yUp
    @State private var showUnfilteredSplat = false
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
        .frame(minWidth: 820, minHeight: 580)
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

    private var captureBrowser: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
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
            showUnfilteredSplat = false
            viewerResetToken += 1
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
                }
                .listStyle(.sidebar)
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
                if let url = model.splatURL(
                    for: capture,
                    unfiltered: showUnfilteredSplat
                ) ?? model.splatURL(for: capture) {
                    completedViewer(url: url, capture: capture)
                } else {
                    failureView(
                        capture,
                        message: "The finished splat is missing."
                    )
                }
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
                Button("Open sample splat") {
                    model.openBundledSample()
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .foregroundStyle(.white)
        }
    }

    private func processingView(_ capture: CaptureRecord) -> some View {
        let progress = model.runningCaptureID == capture.id
            ? model.pipelineProgress
            : nil
        let previewURL = model.runningCaptureID == capture.id
            ? model.instantPreviewURL
            : model.previewURL(for: capture)
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
            }
            VStack(spacing: 30) {
                if previewURL != nil {
                    Text("INSTANT PREVIEW")
                        .font(.system(
                            size: 11,
                            weight: .bold,
                            design: .monospaced
                        ))
                        .tracking(2.2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                }
                VStack(spacing: 7) {
                    Text("BUILDING SCENE")
                        .font(.system(
                            size: 11,
                            weight: .bold,
                            design: .monospaced
                        ))
                        .tracking(2.2)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(stageTitle(progress?.stage, fallback: capture.state))
                        .font(.system(size: 31, weight: .medium, design: .serif))
                        .foregroundStyle(.white)
                }

                ProgressView(value: progress?.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(maxWidth: 420)

                Text("\(Int(((progress?.fraction ?? 0) * 100).rounded()))%")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                StageRail(current: progress?.stage)
                    .frame(maxWidth: 580)

                if model.runningCaptureID == capture.id {
                    Button("Cancel", role: .destructive) {
                        model.cancelCurrentCapture()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(50)
        }
    }

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
                Button("Start over from saved video") {
                    model.retry(capture)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .padding(.top, 8)
            }
            .padding()
        }
    }

    private func completedViewer(
        url: URL,
        capture: CaptureRecord
    ) -> some View {
        ZStack {
            SplatMetalView(
                url: url,
                status: $viewerStatus,
                resetToken: viewerResetToken,
                autoRotate: viewerAutoRotate,
                verticalAxis: viewerVerticalAxis
            )
                .ignoresSafeArea()

            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(capture.sourceFilename)
                            .font(.headline)
                        viewerStatusLabel
                    }
                    .foregroundStyle(.white)
                    Spacer()
                    if model.hasUnfilteredSplat(for: capture) {
                        Picker(
                            "Splat view",
                            selection: Binding(
                                get: { showUnfilteredSplat },
                                set: { newValue in
                                    guard newValue != showUnfilteredSplat else {
                                        return
                                    }
                                    showUnfilteredSplat = newValue
                                    viewerResetToken += 1
                                }
                            )
                        ) {
                            Text("Cleaned").tag(false)
                            Text("Unfiltered").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                        .labelsHidden()
                        .help(
                            "Cleaned is the isolated subject. Unfiltered is the raw training splat."
                        )
                    }
                    Button {
                        presentSavePanel(
                            suggestedName: showUnfilteredSplat
                                ? "splat.ply"
                                : "scene-hq.ply",
                            copying: url
                        )
                    } label: {
                        Label("Export PLY", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    if let meshURL = model.meshURL(for: capture) {
                        Button {
                            presentSavePanel(
                                suggestedName: "mesh.usdz",
                                copying: meshURL
                            )
                        } label: {
                            Label("Export USDZ", systemImage: "cube")
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
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
                .padding(12)
                .background(
                    .black.opacity(0.58),
                    in: RoundedRectangle(cornerRadius: 15)
                )

                Spacer()

                viewerControls
            }
            .padding(20)
        }
    }

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
                verticalAxis: isSample ? .yUp : viewerVerticalAxis
            )
                .ignoresSafeArea()
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isSample ? "Sample splat" : url.lastPathComponent)
                            .font(.headline)
                        viewerStatusLabel
                    }
                    Spacer()
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
                .padding(13)
                .background(
                    .black.opacity(0.58),
                    in: RoundedRectangle(cornerRadius: 15)
                )
                Spacer()
                viewerControls
            }
            .padding(20)
        }
    }

    private func presentSavePanel(suggestedName: String, copying source: URL) {
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

    private var viewerControls: some View {
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
            Text("LEFT DRAG ORBITS · RIGHT DRAG PANS · SCROLL ZOOMS · R RESETS")
                .font(.system(
                    size: 9,
                    weight: .medium,
                    design: .monospaced
                ))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.72))
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.black.opacity(0.55), in: Capsule())
    }

    @ViewBuilder
    private var viewerStatusLabel: some View {
        switch viewerStatus {
        case .idle:
            Text("Ready")
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading…")
            }
        case let .ready(pointCount):
            Text("\(pointCount.formatted()) Gaussians")
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
                Text(capture.state.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                VStack(spacing: 8) {
                    Circle()
                        .fill(color(for: entry.0))
                        .frame(width: 9, height: 9)
                    Text(entry.1)
                        .font(.system(
                            size: 9,
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
