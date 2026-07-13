import XCTest
@testable import PoseCore

final class CLIOptionsTests: XCTestCase {
    func testParsesInputOutputAndQualityFlags() throws {
        let options = try CLIOptions.parse(arguments: [
            "/captures/images",
            "/captures/apple-dataset",
            "--sequential",
            "--high-sensitivity",
        ])

        XCTAssertEqual(options.inputPath, "/captures/images")
        XCTAssertEqual(options.outputPath, "/captures/apple-dataset")
        XCTAssertTrue(options.useSequentialOrdering)
        XCTAssertTrue(options.useHighFeatureSensitivity)
    }
}
