import Foundation
import simd
import SplatIO
import XCTest
@testable import SplatEngine

final class Phase3SupportTests: XCTestCase {
    func testSplatGPUBuffersPackPositionsAndSH() {
        let points = [
            SplatPoint(
                position: SIMD3(1, 2, 3),
                color: .sphericalHarmonicFloat([
                    SIMD3(0.1, 0.2, 0.3),
                    SIMD3(0.4, 0.5, 0.6),
                    SIMD3(0.7, 0.8, 0.9),
                    SIMD3(1.0, 1.1, 1.2),
                ]),
                opacity: .linearFloat(0.75),
                scale: .linearFloat(SIMD3(0.01, 0.02, 0.03)),
                rotation: simd_quatf(real: 1, imag: .zero)
            ),
        ]
        let buffers = SplatGPUBuffers.make(from: points)

        XCTAssertEqual(buffers.count, 1)
        XCTAssertEqual(buffers.sphericalHarmonicsDegree, 1)
        XCTAssertEqual(buffers.positions, [1, 2, 3])
        XCTAssertEqual(buffers.scales[0], 0.01, accuracy: 0.0001)
        XCTAssertEqual(buffers.scales[1], 0.02, accuracy: 0.0001)
        XCTAssertEqual(buffers.scales[2], 0.03, accuracy: 0.0001)
        XCTAssertEqual(buffers.opacities[0], 0.75, accuracy: 0.0001)
        XCTAssertEqual(buffers.rotations.count, 4)
        XCTAssertEqual(buffers.sphericalHarmonics.count, 4 * 3)
    }

    func testSharpPreviewRunnerResolvesMissingBinaryAsNil() {
        XCTAssertNil(
            SharpPreviewRunner.resolveBinary(
                environment: [:],
                homeDirectory: URL(fileURLWithPath: "/tmp/no-savor-home")
            )
        )
    }

    func testSharpPreviewRunnerBuildsPredictArguments() {
        let args = SharpPreviewRunner.makeArguments(
            inputImageURL: URL(fileURLWithPath: "/tmp/frame.jpg"),
            outputDirectoryURL: URL(fileURLWithPath: "/tmp/out")
        )
        XCTAssertEqual(args, [
            "predict",
            "-i", "/tmp/frame.jpg",
            "-o", "/tmp/out",
        ])
    }

    func testSharpPreviewRunnerNoOpsWhenBinaryMissing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let result = try await SharpPreviewRunner.runIfAvailable(
            inputImageURL: root.appendingPathComponent("frame.jpg"),
            outputPLYURL: root.appendingPathComponent("sharp-preview.ply"),
            environment: ["SAVOR_SHARP_BIN": root.appendingPathComponent(
                "missing-sharp"
            ).path]
        )
        XCTAssertNil(result)
    }

    func testPreferredViewerBackendIsMetalSplatterOnCurrentSDK() {
        XCTAssertEqual(SplatViewerBackend.preferred, .metalSplatter)
        XCTAssertTrue(
            SplatViewerBackend.availableBackends.contains(.metalSplatter)
        )
    }
}
