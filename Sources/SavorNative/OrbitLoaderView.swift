import SwiftUI

/// Shown before the first splat preview exists: a miniature of the capture
/// itself — camera dots sweeping a dashed orbit around a breathing core.
/// Falls back to a static diagram when Reduce Motion is on.
struct OrbitLoaderView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            canvas(at: 0)
        } else {
            TimelineView(.animation) { context in
                canvas(
                    at: context.date.timeIntervalSinceReferenceDate
                )
            }
        }
    }

    private func canvas(at time: TimeInterval) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) * 0.36
            let squash: CGFloat = 0.42
            let white = Color.white

            // Dashed orbit path, slowly counter-rotating via dash phase.
            var ring = Path()
            ring.addEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius * squash,
                width: radius * 2,
                height: radius * squash * 2
            ))
            context.stroke(
                ring,
                with: .color(white.opacity(0.22)),
                style: StrokeStyle(
                    lineWidth: 1.2,
                    dash: [4, 6],
                    dashPhase: CGFloat(time * -6)
                )
            )

            // Breathing core.
            let pulse = 0.5 + 0.5 * sin(time * 1.6)
            let coreRadius = radius * (0.16 + 0.03 * pulse)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - coreRadius,
                    y: center.y - coreRadius,
                    width: coreRadius * 2,
                    height: coreRadius * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [
                        white.opacity(0.5 + 0.2 * pulse),
                        white.opacity(0),
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: coreRadius * 1.6
                )
            )

            // Camera dots sweeping the ring, each trailing a short fade.
            for dot in 0..<3 {
                let phase = time * 0.9 + Double(dot) * 2 * .pi / 3
                for trail in 0..<5 {
                    let angle = phase - Double(trail) * 0.09
                    let position = CGPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius * squash
                    )
                    // Dots behind the core render dimmer, as if occluded.
                    let isBehind = sin(angle) < 0
                    let alpha = (trail == 0 ? 0.9 : 0.35 / Double(trail))
                        * (isBehind ? 0.35 : 1)
                    let dotRadius: CGFloat = trail == 0 ? 3 : 2
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: position.x - dotRadius,
                            y: position.y - dotRadius,
                            width: dotRadius * 2,
                            height: dotRadius * 2
                        )),
                        with: .color(white.opacity(alpha))
                    )
                }
            }
        }
        .frame(width: 220, height: 150)
        .accessibilityLabel("Preparing the first preview")
    }
}
