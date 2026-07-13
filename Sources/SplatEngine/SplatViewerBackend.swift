import Foundation

/// Identifies which viewer backend is active. RealityKit lands on macOS 27+.
public enum SplatViewerBackend: String, Sendable, Equatable, CaseIterable {
    case metalSplatter
    case realityKit

    public static var availableBackends: [SplatViewerBackend] {
        let backends: [SplatViewerBackend] = [.metalSplatter]
        if #available(macOS 27.0, *) {
            // GaussianSplatComponent requires the macOS 27 SDK.
            // return backends + [.realityKit]
        }
        return backends
    }

    public static var preferred: SplatViewerBackend {
        availableBackends.first ?? .metalSplatter
    }
}
