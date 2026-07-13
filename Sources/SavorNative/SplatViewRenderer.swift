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
    private var autoRotate = false
    private var lastDrawTime = ProcessInfo.processInfo.systemUptime

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
        view.clearColor = MTLClearColor(
            red: 0.018,
            green: 0.021,
            blue: 0.026,
            alpha: 1
        )
    }

    func load(
        _ url: URL,
        status: @escaping @MainActor (ViewerStatus) -> Void
    ) {
        guard url != loadedURL else {
            return
        }
        loadedURL = url
        splatRenderer = nil
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
                let framing = try SplatSceneFramingResolver.resolve(
                    positions: points.map(\.position),
                    opacities: points.map(\.opacity.asLinearFloat),
                    maxLinearScales: scales,
                    metadata: metadata,
                    transformsURL: TransformsCameraCenters
                        .resolveTransformsURL(near: url)
                )
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
                let displayPoints = SplatDisplayCulling.filterForDisplay(
                    points: points,
                    compactRadius: metadata?.compactRadius,
                    framingRadius: framing.radius
                )
                let chunk = try SplatChunk(device: device, from: displayPoints)
                await renderer.addChunk(chunk)
                try Task.checkCancellation()
                splatRenderer = renderer
                status(.ready(pointCount: displayPoints.count))
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
    }

    func pan(deltaX: Float, deltaY: Float) {
        camera.pan(deltaX: deltaX, deltaY: deltaY)
    }

    func magnify(by amount: Float) {
        camera.zoom(magnification: amount, sensitivity: 1.5)
    }

    func scroll(by amount: Float) {
        camera.zoom(magnification: amount, sensitivity: 0.01)
    }

    func resetCamera() {
        camera = homeCamera
    }

    func setAutoRotate(_ enabled: Bool) {
        autoRotate = enabled
        lastDrawTime = ProcessInfo.processInfo.systemUptime
    }

    func setVerticalAxis(_ verticalAxis: ViewerVerticalAxis) {
        camera.setVerticalAxis(verticalAxis)
        homeCamera.setVerticalAxis(verticalAxis)
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
}
