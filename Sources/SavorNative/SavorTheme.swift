import SwiftUI

/// The app's entire type scale: SF Pro for reading, SF Mono for data.
/// Nothing else — every text style in the UI comes from these seven.
enum SavorFont {
    // SF Pro
    static let display = Font.system(size: 32, weight: .semibold)
    static let title = Font.headline
    static let body = Font.callout
    static let caption = Font.caption
    // SF Mono
    static let monoLabel = Font.system(size: 11, design: .monospaced)
    static let monoBadge = Font.system(
        size: 10,
        weight: .bold,
        design: .monospaced
    )
    static let monoHint = Font.system(
        size: 9,
        weight: .medium,
        design: .monospaced
    )
}

extension View {
    /// Floating-bar chrome over the splat viewer: Liquid Glass on macOS 26,
    /// a translucent panel with a hairline stroke elsewhere. Dark-tinted in
    /// both cases so white viewer text stays readable over bright splats.
    @ViewBuilder
    func savorBar<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular.tint(.black.opacity(0.35)), in: shape)
        } else {
            self
                .background(.black.opacity(0.58), in: shape)
                .overlay(shape.stroke(.white.opacity(0.08), lineWidth: 1))
        }
    }

    /// Layered elevation shadow for floating bars (soft ambient + tight
    /// contact), never pure black.
    func savorBarShadow() -> some View {
        self
            .shadow(color: .black.opacity(0.32), radius: 16, y: 7)
            .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
    }
}
