import Foundation
import XCTest
@testable import PoseCore

final class SampleImageResolverTests: XCTestCase {
    func testUsesPhotogrammetrySampleURLMappingInsteadOfFilenameOrder() throws {
        let firstPoseURL = URL(fileURLWithPath: "/images/z-last.jpg")
        let secondPoseURL = URL(fileURLWithPath: "/images/a-first.jpg")

        let resolved = try SampleImageResolver.orderedURLs(
            forSampleIDs: [0, 1],
            urlsBySample: [
                0: firstPoseURL,
                1: secondPoseURL,
            ]
        )

        XCTAssertEqual(resolved, [firstPoseURL, secondPoseURL])
    }
}
