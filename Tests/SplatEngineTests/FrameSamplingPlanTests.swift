import XCTest
@testable import SplatEngine

final class FrameSamplingPlanTests: XCTestCase {
    func testPlacesSamplesAtEqualWindowMidpoints() throws {
        let seconds = try FrameSamplingPlan.sampleSeconds(
            duration: 10,
            targetCount: 4,
            estimatedFrameCount: 100
        )

        XCTAssertEqual(seconds, [1.25, 3.75, 6.25, 8.75])
    }

    func testRejectsNonPositiveDuration() {
        XCTAssertThrowsError(
            try FrameSamplingPlan.sampleSeconds(
                duration: 0,
                targetCount: 150,
                estimatedFrameCount: 300
            )
        ) { error in
            XCTAssertEqual(error as? FrameSamplingPlan.Error, .invalidDuration)
        }
    }

    func testRejectsNonPositiveFrameCounts() {
        XCTAssertThrowsError(
            try FrameSamplingPlan.sampleSeconds(
                duration: 10,
                targetCount: 0,
                estimatedFrameCount: 300
            )
        ) { error in
            XCTAssertEqual(error as? FrameSamplingPlan.Error, .invalidFrameCount)
        }
    }

    func testDoesNotRequestMoreSamplesThanEstimatedFrames() throws {
        let seconds = try FrameSamplingPlan.sampleSeconds(
            duration: 10,
            targetCount: 150,
            estimatedFrameCount: 2
        )

        XCTAssertEqual(seconds, [2.5, 7.5])
    }
}
