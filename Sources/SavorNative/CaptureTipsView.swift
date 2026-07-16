import SwiftUI

/// "What makes a good capture" guidance, shown from the viewer toolbar.
/// The diagram is drawn with Canvas so it stays crisp at any size and
/// follows the system appearance.
struct CaptureTipsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Filming for a good splat")
                    .font(.title3.weight(.semibold))
                Text("Savor eats any video — these captures come out best.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            OrbitDiagram()
                .frame(height: 190)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 9) {
                tip(
                    good: true,
                    text: "Walk a slow, full circle around one object "
                        + "(20–60 seconds)."
                )
                tip(
                    good: true,
                    text: "Keep the object centered and filling about half "
                        + "the frame."
                )
                tip(
                    good: true,
                    text: "Even, diffuse light — overcast daylight or a "
                        + "well-lit room."
                )
                tip(
                    good: false,
                    text: "Avoid shiny, transparent, or moving subjects."
                )
                tip(
                    good: false,
                    text: "Avoid fast pans and walking toward or away "
                        + "from the object."
                )
            }
            .font(.callout)
        }
        .padding(22)
        .frame(width: 380)
    }

    private func tip(good: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: good ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(good ? Color.green : Color.secondary)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Top-down diagram: subject in the middle, dashed orbit path, camera
/// positions around it all facing inward, with a motion arrow.
private struct OrbitDiagram: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let orbitRadius = min(size.width, size.height) * 0.4

            let primary = Color.primary
            let secondary = Color.secondary

            // Orbit path.
            var orbit = Path()
            orbit.addEllipse(in: CGRect(
                x: center.x - orbitRadius,
                y: center.y - orbitRadius,
                width: orbitRadius * 2,
                height: orbitRadius * 2
            ))
            context.stroke(
                orbit,
                with: .color(secondary.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.4, dash: [5, 5])
            )

            // Motion arrow along the path (top arc, pointing clockwise).
            let arrowAngle = -CGFloat.pi / 3.2
            let arrowTip = point(on: orbitRadius, at: arrowAngle, from: center)
            let tangent = CGVector(
                dx: -sin(arrowAngle),
                dy: cos(arrowAngle)
            )
            var arrow = Path()
            arrow.move(to: arrowTip)
            arrow.addLine(to: CGPoint(
                x: arrowTip.x - tangent.dx * 11 - tangent.dy * 5,
                y: arrowTip.y - tangent.dy * 11 + tangent.dx * 5
            ))
            arrow.addLine(to: CGPoint(
                x: arrowTip.x - tangent.dx * 11 + tangent.dy * 5,
                y: arrowTip.y - tangent.dy * 11 - tangent.dx * 5
            ))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(secondary))

            // Camera dots facing the subject.
            for index in 0..<8 {
                let angle = CGFloat(index) / 8 * 2 * .pi + .pi / 8
                let position = point(
                    on: orbitRadius,
                    at: angle,
                    from: center
                )
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: position.x - 3.5,
                        y: position.y - 3.5,
                        width: 7,
                        height: 7
                    )),
                    with: .color(primary.opacity(0.85))
                )
                // View direction tick toward the subject.
                let inward = CGVector(
                    dx: (center.x - position.x) / orbitRadius,
                    dy: (center.y - position.y) / orbitRadius
                )
                var tick = Path()
                tick.move(to: CGPoint(
                    x: position.x + inward.dx * 6,
                    y: position.y + inward.dy * 6
                ))
                tick.addLine(to: CGPoint(
                    x: position.x + inward.dx * 15,
                    y: position.y + inward.dy * 15
                ))
                context.stroke(
                    tick,
                    with: .color(primary.opacity(0.4)),
                    lineWidth: 1.2
                )
            }

            // Subject: a simple isometric cube.
            let cube = cubePath(center: center, size: orbitRadius * 0.42)
            context.fill(cube.fill, with: .color(primary.opacity(0.14)))
            context.stroke(
                cube.edges,
                with: .color(primary.opacity(0.8)),
                style: StrokeStyle(lineWidth: 1.4, lineJoin: .round)
            )
        }
        .accessibilityLabel(
            "Diagram: walk a full circle around the object, camera always "
                + "pointed at it."
        )
    }

    private func point(
        on radius: CGFloat,
        at angle: CGFloat,
        from center: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius * 0.86
        )
    }

    private func cubePath(
        center: CGPoint,
        size: CGFloat
    ) -> (fill: Path, edges: Path) {
        let half = size / 2
        let depth = size * 0.38
        let top = CGPoint(x: center.x, y: center.y - half)
        let topLeft = CGPoint(x: center.x - half, y: top.y + depth * 0.6)
        let topRight = CGPoint(x: center.x + half, y: top.y + depth * 0.6)
        let middle = CGPoint(x: center.x, y: top.y + depth * 1.2)
        let bottomLeft = CGPoint(x: topLeft.x, y: topLeft.y + half)
        let bottomRight = CGPoint(x: topRight.x, y: topRight.y + half)
        let bottom = CGPoint(x: center.x, y: middle.y + half)

        var outline = Path()
        outline.move(to: top)
        outline.addLine(to: topRight)
        outline.addLine(to: bottomRight)
        outline.addLine(to: bottom)
        outline.addLine(to: bottomLeft)
        outline.addLine(to: topLeft)
        outline.closeSubpath()

        var edges = outline
        edges.move(to: topLeft)
        edges.addLine(to: middle)
        edges.addLine(to: topRight)
        edges.move(to: middle)
        edges.addLine(to: bottom)

        return (outline, edges)
    }
}
