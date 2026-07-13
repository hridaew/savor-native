import Foundation
import XCTest
@testable import SplatEngine

final class CaptureRepositoryTests: XCTestCase {
    func testCreatesCaptureByCopyingSourceAndPersistingMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.mov")
        let captures = root.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("video".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CaptureRepository(rootURL: captures)
        let id = UUID()

        let record = try await repository.createCapture(
            from: source,
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.state, .queued)
        XCTAssertEqual(record.sourceFilename, "source.mov")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repository.sourceVideoURL(for: record).path
        ))
        let loaded = try await repository.loadAll()
        XCTAssertEqual(loaded, [record])
    }

    func testMarksInFlightCaptureInterruptedWhenRelaunched() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.mov")
        let captures = root.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("video".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CaptureRepository(rootURL: captures)
        let record = try await repository.createCapture(from: source)
        _ = try await repository.transition(record.id, to: .training)

        let relaunched = CaptureRepository(rootURL: captures)
        let loaded = try await relaunched.loadRecoveringInterrupted()

        XCTAssertEqual(loaded.first?.state, .interrupted)
        XCTAssertNotNil(loaded.first?.errorMessage)
    }

    func testRelaunchTerminatesOrphanedTrainerProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.mov")
        let captures = root.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("video".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CaptureRepository(rootURL: captures)
        let record = try await repository.createCapture(from: source)
        let trainingURL = repository.workspaceURL(for: record.id)
            .appendingPathComponent("training", isDirectory: true)
        try FileManager.default.createDirectory(
            at: trainingURL,
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        try TrainerProcessLease.write(process: process, to: trainingURL)
        _ = try await repository.transition(record.id, to: .training)

        let relaunched = CaptureRepository(rootURL: captures)
        _ = try await relaunched.loadRecoveringInterrupted()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(process.isRunning)
    }

    func testMigratesLegacyCaptureWithoutChangingRawSplat() async throws {
        let fixture = try await makeCompletedLegacyCapture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rawData = try Data(contentsOf: fixture.rawURL)

        let migrated = try await fixture.repository
            .migrateLegacyCompletedCaptures(
                postprocessor: CopyingPostprocessor()
            )

        let record = try XCTUnwrap(migrated.first)
        XCTAssertEqual(record.splatRelativePath, "output/scene-hq.ply")
        XCTAssertEqual(
            record.rawSplatRelativePath,
            "training/splat_12000.ply"
        )
        XCTAssertEqual(record.cleaning?.keptCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.rawURL), rawData)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.repository.workspaceURL(for: record.id)
                .appendingPathComponent("output/scene-hq.ply").path
        ))
    }

    func testCleaningSummaryIncludesSubjectIsolationCount() throws {
        let result = SplatCleaningResult(
            center: .zero,
            radius: 1,
            compactRadius: 0.4,
            totalCount: 100,
            keptCount: 40,
            floaterCount: 10,
            hazeRemovedCount: 5,
            subjectIsolatedCount: 45,
            planeFound: false,
            orbitRadius: 2,
            isEnvironment: false,
            cameraPosition: nil,
            worldUp: SIMD3(0, 1, 0)
        )
        let summary = CaptureCleaningSummary(result)
        XCTAssertEqual(summary.subjectIsolatedCount, 45)

        let encoded = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(
            CaptureCleaningSummary.self,
            from: encoded
        )
        XCTAssertEqual(decoded.subjectIsolatedCount, 45)
        XCTAssertEqual(decoded.keptCount, 40)
    }

    func testActiveSplatPathPrefersCleanedUnlessUnfiltered() {
        let record = CaptureRecord(
            id: UUID(),
            createdAt: Date(),
            sourceFilename: "demo.mov",
            sourceRelativePath: "source.mov",
            state: .completed,
            splatRelativePath: "output/scene-hq.ply",
            rawSplatRelativePath: "training/splat.ply",
            cleaning: nil,
            errorMessage: nil
        )
        XCTAssertEqual(
            record.activeSplatRelativePath(unfiltered: false),
            "output/scene-hq.ply"
        )
        XCTAssertEqual(
            record.activeSplatRelativePath(unfiltered: true),
            "training/splat.ply"
        )
    }

    func testFailedLegacyMigrationLeavesOriginalCaptureViewable() async throws {
        let fixture = try await makeCompletedLegacyCapture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            _ = try await fixture.repository.migrateLegacyCompletedCaptures(
                postprocessor: FailingPostprocessor()
            )
            XCTFail("Expected migration to fail")
        } catch {
            let loaded = try await fixture.repository.loadAll()
            XCTAssertEqual(
                loaded.first?.splatRelativePath,
                "training/splat_12000.ply"
            )
            XCTAssertNil(loaded.first?.rawSplatRelativePath)
        }
    }

    private func makeCompletedLegacyCapture() async throws -> (
        root: URL,
        repository: CaptureRepository,
        rawURL: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.mov")
        let captures = root.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("video".utf8).write(to: source)
        let repository = CaptureRepository(rootURL: captures)
        let created = try await repository.createCapture(from: source)
        let rawURL = repository.workspaceURL(for: created.id)
            .appendingPathComponent("training/splat_12000.ply")
        try FileManager.default.createDirectory(
            at: rawURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("raw splat".utf8).write(to: rawURL)
        _ = try await repository.transition(
            created.id,
            to: .completed,
            splatRelativePath: "training/splat_12000.ply"
        )
        return (root, repository, rawURL)
    }
}

private struct CopyingPostprocessor: SplatPostprocessing {
    func process(
        inputURL: URL,
        outputURL: URL,
        cameraCenters: [SIMD3<Float>]
    ) async throws -> SplatCleaningResult {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: inputURL, to: outputURL)
        return SplatCleaningResult(
            center: .zero,
            radius: 1,
            compactRadius: 0.5,
            totalCount: 1,
            keptCount: 1,
            floaterCount: 0,
            hazeRemovedCount: 0,
            subjectIsolatedCount: 0,
            planeFound: false,
            orbitRadius: 2,
            isEnvironment: false,
            cameraPosition: nil,
            worldUp: SIMD3(0, 1, 0)
        )
    }
}

private struct FailingPostprocessor: SplatPostprocessing {
    struct ExpectedError: Error {}

    func process(
        inputURL: URL,
        outputURL: URL,
        cameraCenters: [SIMD3<Float>]
    ) async throws -> SplatCleaningResult {
        throw ExpectedError()
    }
}
