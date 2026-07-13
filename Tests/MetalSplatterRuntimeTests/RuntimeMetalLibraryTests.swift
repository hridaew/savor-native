import Metal
import XCTest
@testable import MetalSplatter

final class RuntimeMetalLibraryTests: XCTestCase {
    func testBuildsLibraryFromPackagedShaderSources() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())

        let library = try RuntimeMetalLibrary.make(device: device)

        XCTAssertNotNil(library.makeFunction(
            name: "singleStageSplatVertexShader"
        ))
        XCTAssertNotNil(library.makeFunction(
            name: "multiStageSplatVertexShader"
        ))
    }

    func testSplatRendererInitializesWithoutPrecompiledLibrary() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())

        _ = try SplatRenderer(
            device: device,
            colorFormat: .bgra8Unorm_srgb,
            depthFormat: .depth32Float,
            sampleCount: 1,
            maxViewCount: 1,
            maxSimultaneousRenders: 1
        )
    }
}
