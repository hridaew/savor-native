import SwiftUI

/// Stretch Vision Pro closer. Full visionOS linking needs an Xcode multiplatform
/// app — msplat's vendored XCFramework is macOS-arm64 only, so this target stays
/// a macOS companion that documents the MetalSplatter + shared SplatEngine path.
@main
struct SavorVisionApp: App {
    var body: some Scene {
        WindowGroup {
            VisionContentView()
        }
    }
}

struct VisionContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("Savor Vision")
                .font(.largeTitle.weight(.semibold))
            Text(
                "Shared stack: Photogrammetry (Mac) → msplat Metal train → "
                    + "MetalSplatter / RealityKit splat view on Vision Pro."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
            if let sampleURL = Bundle.module.url(
                forResource: "scene-hq",
                withExtension: "ply",
                subdirectory: "Samples"
            ) {
                Text("Bundled sample ready for Vision Pro viewer wrap:")
                    .font(.caption)
                Text(sampleURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text(
                "Next: Xcode multiplatform target + MetalSplatter visionOS "
                    + "(or GaussianSplatComponent on visionOS 27)."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 480)
            .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(minWidth: 640, minHeight: 420)
    }
}
