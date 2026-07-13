import Foundation
import XCTest
@testable import SplatEngine

final class ImageDirectoryScannerTests: XCTestCase {
    func testReturnsSupportedImagesInFilenameOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("b.jpg"))
        try Data().write(to: directory.appendingPathComponent("a.PNG"))
        try Data().write(to: directory.appendingPathComponent("notes.txt"))

        let images = try ImageDirectoryScanner.imageURLs(in: directory)

        XCTAssertEqual(images.map(\.lastPathComponent), ["a.PNG", "b.jpg"])
    }
}
