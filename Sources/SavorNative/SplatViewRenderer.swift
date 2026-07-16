import Metal
import MetalKit
import MetalSplatter
import os
import SplatEngine
import SplatIO

@MainActor
final class SplatViewRenderer: NSObject, MTKViewDelegate {
    private static let maximumInFlightFrames = 3
    /// Match the original app's viewer: 50° keeps perspective close to the
    /// capture lens; wider FOVs read as distorted next to the source video.
    private static let fovYRadians: Float = 50 * .pi / 180
    private static let logger = Logger(
        subsystem: "com.savor.native",
        category: "SplatViewRenderer"
    )

    private let view: MTKView
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let inFlightSemaphore = DispatchSemaphore(
        value: maximumInFlightFrames
    )

    private var splatRenderer: SplatRenderer?
    private var loadTask: Task<Void, Never>?
    private var loadedURL: URL?
    private var drawableSize: CGSize
    private var camera = OrbitCameraState()
    private var homeCamera = OrbitCameraState()
    private var sceneRadius: Float = 1
    private var sceneCenter = SIMD3<Float>.zero
    private var autoRotate = false
    private var lastDrawTime = ProcessInfo.processInfo.systemUptime

    private var displayPoints: [SplatPoint] = []
    private var statusHandler: (@MainActor (ViewerStatus) -> Void)?

    // Vertical orientation: detected from the capture itself (framing
    // metadata's worldUp, else the camera-ring orbit axis), with the
    // caller's fallback when neither exists and a user "flip" override.
    private var detectedVerticalAxis: ViewerVerticalAxis?
    private var fallbackVerticalAxis: ViewerVerticalAxis = .yUp
    private var flipVertical = false

    // Live-clean scrubber: point indices sorted by "melts first" score.
    private var customCleanOrder: [Int]?
    private var customCleanFraction: Float?
    private var customRebuildTask: Task<Void, Never>?
    // Chunk swaps are chained so two slider ticks can never interleave
    // their remove/add pairs (which would leave two chunks live).
    private var chunkReplaceTask: Task<Void, Never>?

    var isSceneLoaded: Bool {
        splatRenderer != nil && !displayPoints.isEmpty
    }

    init?(_ view: MTKView) {
        guard
            let device = view.device,
            let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }
        self.view = view
        self.device = device
        self.commandQueue = commandQueue
        drawableSize = view.drawableSize
        super.init()

        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 1
        // 60 is plenty for orbiting a static scene; uncapped ProMotion
        // doubles the GPU bill for nothing.
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(
            red: 0.018,
            green: 0.021,
            blue: 0.026,
            alpha: 1
        )
    }

    // MARK: - Idle power

    private var idlePauseTask: Task<Void, Never>?

    /// Keeps the render loop running only while something is moving. After
    /// two quiet seconds the MTKView pauses and draws on demand — idle GPU
    /// use drops to zero instead of re-rendering a static scene at 60 fps.
    private func noteActivity() {
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        idlePauseTask?.cancel()
        guard !autoRotate else {
            return
        }
        idlePauseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, !self.autoRotate else {
                return
            }
            self.view.isPaused = true
            self.view.enableSetNeedsDisplay = true
            self.view.needsDisplay = true
            // A late splat re-sort can improve draw order after pausing;
            // render once more when it lands.
            self.splatRenderer?.afterNextSort { [weak self] in
                Task { @MainActor in
                    self?.view.needsDisplay = true
                }
            }
        }
    }

    func load(
        _ url: URL,
        status: @escaping @MainActor (ViewerStatus) -> Void
    ) {
        statusHandler = status
        guard url != loadedURL else {
            return
        }
        loadedURL = url
        splatRenderer = nil
        displayPoints = []
        customCleanOrder = nil
        customRebuildTask?.cancel()
        chunkReplaceTask?.cancel()
        loadTask?.cancel()
        status(.loading)

        loadTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let renderer = try SplatRenderer(
                    device: device,
                    colorFormat: view.colorPixelFormat,
                    depthFormat: view.depthStencilPixelFormat,
                    sampleCount: view.sampleCount,
                    maxViewCount: 1,
                    maxSimultaneousRenders: Self.maximumInFlightFrames
                )
                let reader = try AutodetectSceneReader(url)
                let points = try await reader.readAll()
                try Task.checkCancellation()
                let scales = points.map { point -> Float in
                    let scale = point.scale.asLinearFloat
                    return max(scale.x, max(scale.y, scale.z))
                }
                let metadata = SplatFramingMetadata.load(near: url)
                let transformsURL = TransformsCameraCenters
                    .resolveTransformsURL(near: url)
                let framing = try SplatSceneFramingResolver.resolve(
                    positions: points.map(\.position),
                    opacities: points.map(\.opacity.asLinearFloat),
                    maxLinearScales: scales,
                    metadata: metadata,
                    transformsURL: transformsURL
                )
                // Orient the scene right-side-up from the capture itself:
                // the cleaner's recorded worldUp when present, else the
                // camera-ring orbit axis from transforms.json.
                detectedVerticalAxis = Self.detectVerticalAxis(
                    metadata: metadata,
                    transformsURL: transformsURL,
                    subjectCenter: framing.center
                )
                let verticalAxis = effectiveVerticalAxis()
                camera.setVerticalAxis(verticalAxis)
                camera.fit(
                    target: framing.center,
                    radius: framing.radius,
                    fovYRadians: Self.fovYRadians
                )
                // Start from where the capture cameras were (median capture
                // position, cleaned CRS): the scene only exists as seen from
                // near the orbit path, so the background reads correctly.
                if let capturePosition = metadata?.cameraPositionVector,
                   metadata?.isEnvironment != true {
                    camera.look(
                        from: capturePosition,
                        at: framing.center
                    )
                }
                homeCamera = camera
                sceneRadius = framing.radius
                sceneCenter = framing.center
                let culled = SplatDisplayCulling.filterForDisplay(
                    points: points,
                    compactRadius: metadata?.compactRadius,
                    framingRadius: framing.radius
                )
                displayPoints = culled
                let chunk = try SplatChunk(device: device, from: culled)
                await renderer.addChunk(chunk)
                try Task.checkCancellation()
                splatRenderer = renderer
                if let fraction = customCleanFraction {
                    applyCustomClean(fraction: fraction)
                } else {
                    status(.ready(pointCount: culled.count))
                }
                noteActivity()
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error(
                    "Unable to load splat: \(error.localizedDescription)"
                )
                status(.failed(message: error.localizedDescription))
            }
        }
    }

    func orbit(deltaX: Float, deltaY: Float) {
        camera.orbit(deltaX: deltaX, deltaY: deltaY)
        noteActivity()
    }

    func pan(deltaX: Float, deltaY: Float) {
        camera.pan(deltaX: deltaX, deltaY: deltaY)
        noteActivity()
    }

    func magnify(by amount: Float) {
        camera.zoom(magnification: amount, sensitivity: 1.5)
        noteActivity()
    }

    func scroll(by amount: Float) {
        camera.zoom(magnification: amount, sensitivity: 0.01)
        noteActivity()
    }

    func resetCamera() {
        camera = homeCamera
        noteActivity()
    }

    func setAutoRotate(_ enabled: Bool) {
        guard enabled != autoRotate else {
            return
        }
        autoRotate = enabled
        lastDrawTime = ProcessInfo.processInfo.systemUptime
        noteActivity()
    }

    func setVerticalOrientation(
        fallback: ViewerVerticalAxis,
        flip: Bool
    ) {
        guard fallback != fallbackVerticalAxis || flip != flipVertical else {
            return
        }
        fallbackVerticalAxis = fallback
        flipVertical = flip
        let axis = effectiveVerticalAxis()
        camera.setVerticalAxis(axis)
        homeCamera.setVerticalAxis(axis)
        noteActivity()
    }

    private func effectiveVerticalAxis() -> ViewerVerticalAxis {
        var axis = detectedVerticalAxis ?? fallbackVerticalAxis
        if flipVertical {
            axis = axis == .yUp ? .yDown : .yUp
        }
        return axis
    }

    func draw(in view: MTKView) {
        guard
            let splatRenderer,
            splatRenderer.isReadyToRender,
            drawableSize.width > 0,
            drawableSize.height > 0,
            let drawable = view.currentDrawable
        else {
            return
        }

        let drawTime = ProcessInfo.processInfo.systemUptime
        if autoRotate {
            let elapsed = min(0.1, max(0, drawTime - lastDrawTime))
            camera.advanceYaw(by: Float(elapsed) * 0.35)
        }
        lastDrawTime = drawTime

        inFlightSemaphore.wait()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }

        let width = drawableSize.width
        let height = drawableSize.height
        let descriptor = SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(
                originX: 0,
                originY: 0,
                width: width,
                height: height,
                znear: 0,
                zfar: 1
            ),
            projectionMatrix: OrbitCameraMatrices.perspectiveProjection(
                fovYRadians: Self.fovYRadians,
                aspectRatio: Float(width / height),
                nearZ: max(0.005, sceneRadius * 0.005),
                farZ: max(100, camera.distance + sceneRadius * 6)
            ),
            viewMatrix: OrbitCameraMatrices.viewMatrix(for: camera),
            screenSize: SIMD2(Int(width), Int(height))
        )

        let didRender: Bool
        do {
            didRender = try splatRenderer.render(
                viewports: [descriptor],
                colorTexture: view.multisampleColorTexture ?? drawable.texture,
                colorStoreAction: view.multisampleColorTexture == nil
                    ? .store
                    : .multisampleResolve,
                depthTexture: view.depthStencilTexture,
                rasterizationRateMap: nil,
                renderTargetArrayLength: 0,
                to: commandBuffer
            )
        } catch {
            Self.logger.error(
                "Unable to render splat: \(error.localizedDescription)"
            )
            didRender = false
        }

        if didRender {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    /// Maps a detected world-up direction onto the viewer's y-axis choice.
    private static func detectVerticalAxis(
        metadata: SplatFramingMetadata?,
        transformsURL: URL?,
        subjectCenter: SIMD3<Float>
    ) -> ViewerVerticalAxis? {
        if let metadata {
            // Cleaned scene: positions are normalized, so the raw-CRS camera
            // transforms can't be compared against them — only the recorded
            // worldUp (direction survives the translate+scale) is usable.
            guard let worldUp = metadata.worldUpVector else {
                return nil
            }
            return worldUp.y >= 0 ? .yUp : .yDown
        }
        guard let transformsURL else {
            return nil
        }
        let cameraCenters = TransformsCameraCenters.load(from: transformsURL)
        guard let axis = OrbitUpEstimator.estimate(
            cameraCenters: cameraCenters,
            subjectCenter: subjectCenter
        ) else {
            return nil
        }
        return axis.y >= 0 ? .yUp : .yDown
    }

    // MARK: - Live clean scrubber

    /// 0 shows everything the file contains; 1 melts the scene down to the
    /// densest core around the subject. `nil` restores the normal display set.
    func setCustomCleanFraction(_ fraction: Float?) {
        guard fraction != customCleanFraction else {
            return
        }
        customCleanFraction = fraction
        guard splatRenderer != nil, !displayPoints.isEmpty else {
            return
        }
        customRebuildTask?.cancel()
        customRebuildTask = Task { @MainActor [weak self] in
            // Coalesce slider ticks; one rebuild per ~1 frame of dragging.
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else {
                return
            }
            if let fraction = self.customCleanFraction {
                self.applyCustomClean(fraction: fraction)
            } else {
                self.scheduleChunkReplace(with: self.displayPoints)
            }
        }
    }

    private func applyCustomClean(fraction: Float) {
        if customCleanOrder == nil {
            // Melt order: far-from-subject and translucent points go first,
            // so dragging reads as the environment dissolving around the
            // subject rather than a hard radial crop.
            let center = sceneCenter
            let scores = displayPoints.map { point -> Float in
                let distance = simd_length(point.position - center)
                let opacity = point.opacity.asLinearFloat
                return distance * (1 + (1 - opacity) * 0.75)
            }
            customCleanOrder = (0..<displayPoints.count).sorted {
                scores[$0] < scores[$1]
            }
        }
        guard let order = customCleanOrder else {
            return
        }
        // Exponential keep curve: environment mass dominates the far ranks,
        // so equal slider motion should shed roughly equal visual mass.
        let keepFraction = pow(0.04, fraction)
        let keepCount = max(1, Int(Float(order.count) * keepFraction))
        let kept = order.prefix(keepCount).map { displayPoints[$0] }
        scheduleChunkReplace(with: kept)
    }

    private func scheduleChunkReplace(with points: [SplatPoint]) {
        let previous = chunkReplaceTask
        chunkReplaceTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else {
                return
            }
            guard let splatRenderer = self.splatRenderer else {
                return
            }
            do {
                let chunk = try SplatChunk(device: self.device, from: points)
                await splatRenderer.removeAllChunks()
                await splatRenderer.addChunk(chunk)
                self.statusHandler?(.ready(pointCount: points.count))
                self.noteActivity()
            } catch {
                Self.logger.error(
                    "Unable to rebuild chunk: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Offscreen rendering (image + orbit video export)

    private struct OffscreenTarget {
        let color: MTLTexture
        let depth: MTLTexture
        let width: Int
        let height: Int
    }

    private func makeOffscreenTarget(
        width: Int,
        height: Int
    ) throws -> OffscreenTarget {
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        guard
            let color = device.makeTexture(descriptor: colorDescriptor),
            let depth = device.makeTexture(descriptor: depthDescriptor)
        else {
            throw ExportError.textureUnavailable
        }
        return OffscreenTarget(
            color: color,
            depth: depth,
            width: width,
            height: height
        )
    }

    /// Renders one frame with `camera` into `target`, waiting for the
    /// renderer's async splat sort when needed.
    private func renderOffscreen(
        camera: OrbitCameraState,
        into target: OffscreenTarget
    ) async throws {
        guard let splatRenderer else {
            throw ExportError.sceneNotLoaded
        }
        let descriptor = SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(target.width),
                height: Double(target.height),
                znear: 0,
                zfar: 1
            ),
            projectionMatrix: OrbitCameraMatrices.perspectiveProjection(
                fovYRadians: Self.fovYRadians,
                aspectRatio: Float(target.width) / Float(target.height),
                nearZ: max(0.005, sceneRadius * 0.005),
                farZ: max(100, camera.distance + sceneRadius * 6)
            ),
            viewMatrix: OrbitCameraMatrices.viewMatrix(for: camera),
            screenSize: SIMD2(target.width, target.height)
        )
        for _ in 0..<40 {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw ExportError.commandBufferUnavailable
            }
            let rendered = try splatRenderer.render(
                viewports: [descriptor],
                colorTexture: target.color,
                colorStoreAction: .store,
                depthTexture: target.depth,
                rasterizationRateMap: nil,
                renderTargetArrayLength: 0,
                sortTimeout: 1,
                to: commandBuffer
            )
            if rendered {
                let outcome: (
                    status: MTLCommandBufferStatus,
                    error: (any Swift.Error)?
                ) = await withCheckedContinuation { continuation in
                    commandBuffer.addCompletedHandler { buffer in
                        continuation.resume(
                            returning: (buffer.status, buffer.error)
                        )
                    }
                    commandBuffer.commit()
                }
                guard outcome.status == .completed else {
                    throw outcome.error
                        ?? ExportError.commandBufferUnavailable
                }
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ExportError.rendererNotReady
    }

    /// Snapshot of the current viewpoint at the viewport's native (retina)
    /// pixel resolution.
    func snapshotImage() async throws -> CGImage {
        let target = try makeOffscreenTarget(
            width: max(640, Int(drawableSize.width)),
            height: max(480, Int(drawableSize.height))
        )
        try await renderOffscreen(camera: camera, into: target)
        return try Self.image(from: target)
    }

    /// Renders a full 360° orbit around the current target and writes an
    /// H.264 movie. The interactive draw loop keeps running; frames are
    /// rendered between its draws on the same queue.
    func exportOrbitVideo(
        to outputURL: URL,
        duration: Double = 8,
        framesPerSecond: Int = 30,
        size: CGSize = CGSize(width: 1_920, height: 1_080),
        audioSourceURL: URL? = nil,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let frameCount = max(1, Int(duration * Double(framesPerSecond)))
        // The interactive draw loop renders with a different camera, which
        // would force a splat re-sort between every export frame — pause it.
        view.isPaused = true
        defer {
            noteActivity()
        }
        let target = try makeOffscreenTarget(
            width: Int(size.width),
            height: Int(size.height)
        )
        let writer = try await OrbitVideoWriter.make(
            outputURL: outputURL,
            width: target.width,
            height: target.height,
            framesPerSecond: framesPerSecond,
            audioSourceURL: audioSourceURL,
            duration: duration
        )
        var orbitCamera = camera
        for frame in 0..<frameCount {
            try Task.checkCancellation()
            try await renderOffscreen(camera: orbitCamera, into: target)
            try await writer.append(
                texture: target.color,
                frameIndex: frame
            )
            orbitCamera.advanceYaw(by: 2 * .pi / Float(frameCount))
            progress(Double(frame + 1) / Double(frameCount))
        }
        try await writer.finish()
    }

    private static func image(from target: OffscreenTarget) throws -> CGImage {
        let bytesPerRow = target.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * target.height)
        target.color.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, target.width, target.height),
            mipmapLevel: 0
        )
        guard
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let image = CGImage(
                width: target.width,
                height: target.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                ).union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            throw ExportError.imageEncodingFailed
        }
        return image
    }
}

enum ExportError: LocalizedError {
    case sceneNotLoaded
    case textureUnavailable
    case commandBufferUnavailable
    case rendererNotReady
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .sceneNotLoaded:
            "The splat has not finished loading yet."
        case .textureUnavailable:
            "Could not allocate an export texture."
        case .commandBufferUnavailable:
            "Could not create a Metal command buffer."
        case .rendererNotReady:
            "The splat renderer did not become ready."
        case .imageEncodingFailed:
            "Could not encode the exported image."
        }
    }
}
