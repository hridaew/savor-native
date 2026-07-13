import Foundation
import XCTest
@testable import PoseCore

final class DatasetImageLinkerTests: XCTestCase {
    func testRejectsReusingOutputWithDifferentImageDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let firstInput = root.appending(path: "first", directoryHint: .isDirectory)
        let secondInput = root.appending(path: "second", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        for url in [firstInput, secondInput, output] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        try DatasetImageLinker.ensureLink(from: firstInput, into: output)

        XCTAssertThrowsError(
            try DatasetImageLinker.ensureLink(from: secondInput, into: output)
        ) { error in
            XCTAssertEqual(
                error as? DatasetImageLinker.Error,
                .conflictingDestination
            )
        }
    }
}
