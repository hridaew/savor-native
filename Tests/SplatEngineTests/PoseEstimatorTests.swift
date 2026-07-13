import XCTest
@testable import SplatEngine

final class PoseEstimatorTests: XCTestCase {
    func testDefaultsToVideoOptimizedPhotogrammetrySettings() {
        let options = PoseEstimationOptions()

        XCTAssertTrue(options.useSequentialOrdering)
        XCTAssertTrue(options.useHighFeatureSensitivity)
        XCTAssertFalse(options.isObjectMaskingEnabled)
    }
}
