import Foundation
import simd

public protocol SplatPostprocessing: Sendable {
    func process(
        inputURL: URL,
        outputURL: URL,
        cameraCenters: [SIMD3<Float>]
    ) async throws -> SplatCleaningResult
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
        cameraCenters: [SIMD3<Float>]
    ) async throws -> SplatCleaningResult {
        try await SplatCleaner.clean(
            inputURL: inputURL,
            outputURL: outputURL,
            cameraCenters: cameraCenters,
            configuration: configuration
        )
    }
}
