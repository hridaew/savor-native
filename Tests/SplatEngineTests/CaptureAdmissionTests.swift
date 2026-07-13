import XCTest
@testable import SplatEngine

final class CaptureAdmissionTests: XCTestCase {
    func testBlocksSecondCaptureUntilOwnerReleasesAdmission() {
        var admission = CaptureAdmission()

        XCTAssertTrue(admission.reserve())
        XCTAssertFalse(admission.reserve())
        admission.release()
        XCTAssertTrue(admission.reserve())
    }
}
