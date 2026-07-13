import Foundation
import XCTest
@testable import PoseCore

final class PointCloudPLYTests: XCTestCase {
    func testEncodesPositionsAndColorsAsASCIIPLY() throws {
        let point = PointCloudPoint(
            position: Vector3(x: 1.25, y: -2.5, z: 3),
            color: RGBColor(red: 255, green: 128, blue: 0)
        )

        let data = PointCloudPLYEncoder.encode(points: [point])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(
            text,
            """
            ply
            format ascii 1.0
            element vertex 1
            property float x
            property float y
            property float z
            property uchar red
            property uchar green
            property uchar blue
            end_header
            1.25 -2.5 3.0 255 128 0

            """
        )
    }

    func testReadsVertexCountFromBinaryPLYHeader() throws {
        var data = Data(
            """
            ply
            format binary_little_endian 1.0
            element vertex 70087
            end_header

            """.utf8
        )
        data.append(contentsOf: [0x00, 0xFF, 0x7F])

        XCTAssertEqual(try PLYHeaderReader.vertexCount(in: data), 70_087)
    }
}
