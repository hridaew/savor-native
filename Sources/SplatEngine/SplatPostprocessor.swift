import Foundation
import simd

public protocol SplatPostprocessing: Sendable {
    /// `datasetURL` (the capture's Nerfstudio dataset with frames and
    /// transforms) enables silhouette-consensus subject isolation; nil runs
    /// geometric cleanup only.
    func process(
        inputURL: URL,
        outputURL: URL,
        cameraCenters: [SIMD3<Float>],
        datasetURL: URL?
    ) async throws -> SplatCleaningResult
}

public extension SplatPostprocessing {
    func process(
        inputURL: URL,
        outputURL: URL,
        cameraCenters: [SIMD3<Float>]
    ) async throws -> SplatCleaningResult {
        try await process(
            inputURL: inputURL,
            outputURL: outputURL,
            cameraCenters: cameraCenters,
            datasetURL: nil
        )
    }
}

public struct NativeSplatPostprocessor: SplatPostprocessing {
    private let configuration: SplatCleaningConfiguration

    public init(
        configuration: SplatCleaningConfiguration =
            SplatCleaningConfiguration()
    ) {
        self.configuration = configuration
    }

    public func process(
        inputURL: URL,
        outputURL: URL,
        cameraCenters: [SIMD3<Float>],
        datasetURL: URL?
    ) async throws -> SplatCleaningResult {
        // Vision segmentation is blocking work; keep it off the cooperative
        // pool. Best-effort: nil silhouettes fall back to geometric cleanup.
        var silhouettes: SubjectSilhouettes?
        if let datasetURL {
            silhouettes = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        returning: SubjectMaskGenerator.silhouettes(
                            datasetURL: datasetURL
                        )
                    )
                }
            }
        }
        return try await SplatCleaner.clean(
            inputURL: inputURL,
            outputURL: outputURL,
            cameraCenters: cameraCenters,
            silhouettes: silhouettes,
            configuration: configuration
        )
    }
}
