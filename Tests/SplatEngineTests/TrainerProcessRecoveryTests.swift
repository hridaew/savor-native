import Foundation
import XCTest
@testable import SplatEngine

final class TrainerProcessRecoveryTests: XCTestCase {
    func testTerminatesPersistedTrainerProcessWithMatchingIdentity() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        try TrainerProcessLease.write(process: process, to: outputURL)

        let result = TrainerProcessRecovery.terminateStaleProcess(
            in: outputURL
        )
        process.waitUntilExit()

        XCTAssertEqual(result, .terminated)
        XCTAssertFalse(process.isRunning)
    }

    func testDoesNotTerminateReusedPIDWithDifferentStartTime() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        try TrainerProcessLease.write(process: process, to: outputURL)
        let leaseURL = outputURL.appendingPathComponent(
            TrainerProcessLease.filename
        )
        let persisted = try JSONDecoder().decode(
            TrainerProcessLease.self,
            from: Data(contentsOf: leaseURL)
        )
        let reusedPID = TrainerProcessLease(
            processIdentifier: persisted.processIdentifier,
            executablePath: persisted.executablePath,
            startTimeSeconds: persisted.startTimeSeconds + 1,
            startTimeMicroseconds: persisted.startTimeMicroseconds
        )
        try JSONEncoder().encode(reusedPID).write(to: leaseURL)

        let result = TrainerProcessRecovery.terminateStaleProcess(
            in: outputURL
        )

        XCTAssertEqual(result, .identityMismatch)
        XCTAssertTrue(process.isRunning)
    }
}
