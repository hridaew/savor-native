import Foundation
import XCTest
@testable import SplatEngine

final class CaptureRootLockTests: XCTestCase {
    func testAllowsOnlyOneCaptureOwnerAtATime() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        var first: CaptureRootLock? = try CaptureRootLock(rootURL: rootURL)
        XCTAssertNotNil(first)

        XCTAssertThrowsError(try CaptureRootLock(rootURL: rootURL)) { error in
            XCTAssertEqual(
                error as? CaptureRootLock.Error,
                .alreadyLocked
            )
        }

        first = nil
        XCTAssertNoThrow(try CaptureRootLock(rootURL: rootURL))
    }
}
