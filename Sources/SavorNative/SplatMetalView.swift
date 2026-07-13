import AppKit
import MetalKit
import SplatEngine
import SwiftUI

struct SplatMetalView: NSViewRepresentable {
    let url: URL
    @Binding var status: ViewerStatus
    let resetToken: Int
    let autoRotate: Bool
    let verticalAxis: ViewerVerticalAxis

    @MainActor
    final class Coordinator: NSObject {
        var renderer: SplatViewRenderer?
        var status: Binding<ViewerStatus>
        var appliedResetToken: Int
        private var previousOrbitTranslation = CGPoint.zero
        private var previousPanTranslation = CGPoint.zero

        init(status: Binding<ViewerStatus>, resetToken: Int) {
            self.status = status
            appliedResetToken = resetToken
        }

        @objc
        func orbit(_ recognizer: NSPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            switch recognizer.state {
            case .began:
                previousOrbitTranslation = translation
            case .changed:
                let delta = CGPoint(
                    x: translation.x - previousOrbitTranslation.x,
                    y: translation.y - previousOrbitTranslation.y
                )
                renderer?.orbit(
                    deltaX: Float(delta.x),
                    deltaY: Float(delta.y)
                )
                previousOrbitTranslation = translation
            default:
                previousOrbitTranslation = .zero
            }
        }

        @objc
        func pan(_ recognizer: NSPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            switch recognizer.state {
            case .began:
                previousPanTranslation = translation
            case .changed:
                let delta = CGPoint(
                    x: translation.x - previousPanTranslation.x,
                    y: translation.y - previousPanTranslation.y
                )
                renderer?.pan(
                    deltaX: Float(delta.x),
                    deltaY: Float(delta.y)
                )
                previousPanTranslation = translation
            default:
                previousPanTranslation = .zero
            }
        }

        @objc
        func magnify(_ recognizer: NSMagnificationGestureRecognizer) {
            renderer?.magnify(by: Float(recognizer.magnification))
            recognizer.magnification = 0
        }

        @objc
        func resetCamera() {
            renderer?.resetCamera()
        }

        func report(_ newStatus: ViewerStatus) {
            status.wrappedValue = newStatus
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(status: $status, resetToken: resetToken)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = InteractiveMetalView()
        view.device = MTLCreateSystemDefaultDevice()

        guard let renderer = SplatViewRenderer(view) else {
            context.coordinator.report(
                .failed(message: "Metal is unavailable on this Mac.")
            )
            return view
        }
        context.coordinator.renderer = renderer
        view.delegate = renderer
            renderer.setAutoRotate(autoRotate)
            renderer.setVerticalAxis(verticalAxis)
        view.onScroll = { [weak renderer] delta in
            renderer?.scroll(by: Float(delta))
        }
            view.onReset = { [weak renderer] in
                renderer?.resetCamera()
            }

            let orbit = NSPanGestureRecognizer(
            target: context.coordinator,
                action: #selector(Coordinator.orbit(_:))
        )
            orbit.buttonMask = 0x1
            view.addGestureRecognizer(orbit)
            let pan = NSPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.pan(_:))
            )
            pan.buttonMask = 0x2
            view.addGestureRecognizer(pan)
        view.addGestureRecognizer(NSMagnificationGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.magnify(_:))
        ))
            let doubleClick = NSClickGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.resetCamera)
            )
            doubleClick.numberOfClicksRequired = 2
            view.addGestureRecognizer(doubleClick)

        renderer.load(url) { [weak coordinator = context.coordinator] status in
            coordinator?.report(status)
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.status = $status
            context.coordinator.renderer?.setAutoRotate(autoRotate)
            context.coordinator.renderer?.setVerticalAxis(verticalAxis)
            if context.coordinator.appliedResetToken != resetToken {
                context.coordinator.appliedResetToken = resetToken
                context.coordinator.renderer?.resetCamera()
            }
        context.coordinator.renderer?.load(url) {
            [weak coordinator = context.coordinator] status in
            coordinator?.report(status)
        }
    }
}

@MainActor
private final class InteractiveMetalView: MTKView {
    var onScroll: ((CGFloat) -> Void)?
    var onReset: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "r" {
            onReset?()
            return
        }
        super.keyDown(with: event)
    }
}
