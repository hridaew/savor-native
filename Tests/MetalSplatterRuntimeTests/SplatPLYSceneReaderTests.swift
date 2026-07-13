import Foundation
import SplatIO
import XCTest

final class SplatPLYSceneReaderTests: XCTestCase {
    func testReadsDegreeTwoSphericalHarmonics() async throws {
        var header = [
            "ply",
            "format ascii 1.0",
            "element vertex 1",
            "property float x",
            "property float y",
            "property float z",
            "property float f_dc_0",
            "property float f_dc_1",
            "property float f_dc_2",
        ]
        header.append(contentsOf: (0..<24).map {
            "property float f_rest_\($0)"
        })
        header.append(contentsOf: [
            "property float opacity",
            "property float scale_0",
            "property float scale_1",
            "property float scale_2",
            "property float rot_0",
            "property float rot_1",
            "property float rot_2",
            "property float rot_3",
            "end_header",
        ])
        let values = [
            "0", "0", "0",
            "1", "2", "3",
        ] + (0..<24).map(String.init) + [
            "0",
            "0", "0", "0",
            "1", "0", "0", "0",
        ]
        let data = Data(
            (header + [values.joined(separator: " ")])
                .joined(separator: "\n")
                .appending("\n")
                .utf8
        )

        let points = try await SplatPLYSceneReader(data).readAll()

        let point = try XCTUnwrap(points.first)
        guard case let .sphericalHarmonicFloat(coefficients) = point.color else {
            return XCTFail("Expected spherical harmonic color")
        }
        XCTAssertEqual(coefficients.count, 9)
        XCTAssertEqual(coefficients[0], SIMD3(1, 2, 3))
        XCTAssertEqual(coefficients[1], SIMD3(0, 8, 16))
        XCTAssertEqual(coefficients[8], SIMD3(7, 15, 23))
    }
}
