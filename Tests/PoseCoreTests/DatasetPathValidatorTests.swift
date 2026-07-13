import Foundation
import XCTest
@testable import PoseCore

final class DatasetPathValidatorTests: XCTestCase {
    func testRejectsUsingInputDirectoryAsOutput() {
        let input = URL(fileURLWithPath: "/captures/images", isDirectory: true)

        XCTAssertThrowsError(
            try DatasetPathValidator.validateDisjoint(
                inputURL: input,
                outputURL: input
            )
        ) { error in
            XCTAssertEqual(
                error as? DatasetPathValidator.Error,
                .overlappingPaths
            )
        }
    }

    func testRejectsOutputNestedInsideInputDirectory() {
        let input = URL(fileURLWithPath: "/captures/images", isDirectory: true)
        let output = input.appending(
            path: "generated-dataset",
            directoryHint: .isDirectory
        )

        XCTAssertThrowsError(
            try DatasetPathValidator.validateDisjoint(
                inputURL: input,
                outputURL: output
            )
        ) { error in
            XCTAssertEqual(
                error as? DatasetPathValidator.Error,
                .overlappingPaths
            )
        }
    }

    func testResolvesSymlinkedParentBeforeCheckingOverlap() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let input = root.appending(path: "images", directoryHint: .isDirectory)
        let alias = root.appending(path: "alias", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: input,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: input
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try DatasetPathValidator.validateDisjoint(
                inputURL: input,
                outputURL: alias.appending(path: "dataset")
            )
        ) { error in
            XCTAssertEqual(
                error as? DatasetPathValidator.Error,
                .overlappingPaths
            )
        }
    }
}
