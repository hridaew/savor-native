import Foundation
import Msplat
import XCTest
@testable import SplatEngine

final class MsplatBackendTests: XCTestCase {
    func testBuildsPinnedNativeCLIArguments() {
        let dataset = URL(fileURLWithPath: "/tmp/dataset")
        let output = URL(fileURLWithPath: "/tmp/output/splat.ply")

        let arguments = MsplatArguments.make(
            datasetURL: dataset,
            outputPLYURL: output,
            options: TrainingOptions()
        )

        XCTAssertEqual(arguments, [
            "/tmp/dataset",
            "-o", "/tmp/output/splat.ply",
            "-n", "15000",
            "--save-every", "3000",
            "--sh-degree", "2",
            "--refine-every", "100",
            "--warmup-length", "500",
            "--reset-alpha-every", "30",
            "--densify-grad-thresh", "0.0002",
            "--densify-size-thresh", "0.01",
            "--stop-screen-size-at", "4000",
            "--split-screen-size", "0.05",
            "--keep-crs",
        ])
    }

    func testLocatorRequiresExecutableAndAdjacentMetallib() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let executable = root.appendingPathComponent("msplat")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        XCTAssertNil(MsplatExecutableLocator.validate(directoryURL: root))

        try Data("metal".utf8).write(
            to: root.appendingPathComponent("default.metallib")
        )
        XCTAssertEqual(
            MsplatExecutableLocator.validate(directoryURL: root)?
                .executableURL,
            executable
        )
    }

    func testLocatesBundledPinnedRuntime() throws {
        let runtime = try XCTUnwrap(
            MsplatExecutableLocator.locate(environment: [:])
        )

        XCTAssertEqual(runtime.version, "1.1.3")
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: runtime.executableURL.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: runtime.metallibURL.path
        ))
    }

    func testParsesCommonProgressLines() {
        XCTAssertEqual(
            MsplatProgressParser.step(in: "step=3000 splats=42"),
            3_000
        )
        XCTAssertEqual(
            MsplatProgressParser.step(in: "[6000/12000] loss=0.1"),
            6_000
        )
        XCTAssertNil(MsplatProgressParser.step(in: "loading dataset"))
    }

    func testMapsTrainingOptionsIntoInProcessConfig() {
        let options = TrainingOptions(
            totalSteps: 7_000,
            sphericalHarmonicsDegree: 2,
            refineEvery: 150,
            resetAlphaEvery: 25,
            densifyGradThresh: 0.0004,
            stopScreenSizeAt: 3_000
        )
        let config = MsplatTrainingConfigMapper.makeConfig(from: options)

        XCTAssertEqual(config.iterations, 7_000)
        XCTAssertEqual(config.shDegree, 2)
        XCTAssertTrue(config.keepCrs)
        XCTAssertEqual(config.refineEvery, 150)
        XCTAssertEqual(config.resetAlphaEvery, 25)
        XCTAssertEqual(config.densifyGradThresh, 0.0004, accuracy: 0.000_000_1)
        XCTAssertEqual(config.stopScreenSizeAt, 3_000)
        // Coarse-to-fine stays at the library default so in-process training
        // matches the CLI the quality bakes ran through.
        XCTAssertEqual(config.numDownscales, TrainingConfig().numDownscales)
    }

    func testFactorySelectsCLIWhenForced() throws {
        let fixture = try makeFakeRuntime(body: "true")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let backend = try MsplatTrainerFactory.make(
            environment: [
                "SAVOR_MSPLAT_BACKEND": "cli",
                "SAVOR_MSPLAT_DIR": fixture.root.path,
            ]
        )

        XCTAssertTrue(backend is MsplatBackend)
    }

    func testFactoryDefaultsToInProcess() throws {
        let backend = try MsplatTrainerFactory.make(environment: [:])
        XCTAssertTrue(backend is MsplatInProcessBackend)
    }

    func testRunsCLIAndReturnsFinalPLY() async throws {
        let fixture = try makeFakeRuntime(
            body: """
            output=""
            steps=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o) output="$2"; shift 2 ;;
                -n) steps="$2"; shift 2 ;;
                *) shift ;;
              esac
            done
            echo "step=$steps splats=1"
            printf 'ply\\nformat ascii 1.0\\nelement vertex 1\\nend_header\\n' > "$output"
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent(
            "training",
            isDirectory: true
        )
        let backend = MsplatBackend(runtime: fixture.runtime)

        let result = try await backend.train(
            datasetURL: fixture.root,
            outputURL: output,
            options: TrainingOptions(),
            progress: nil
        )

        XCTAssertEqual(result.steps, 15_000)
        XCTAssertEqual(result.gaussianCount, 1)
        XCTAssertEqual(result.plyURL.lastPathComponent, "splat.ply")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: output.appendingPathComponent(
                TrainerProcessLease.filename
            ).path
        ))
    }

    func testCancellationTerminatesCLIAndRemovesLease() async throws {
        let fixture = try makeFakeRuntime(body: "sleep 2")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent(
            "training",
            isDirectory: true
        )
        let backend = MsplatBackend(runtime: fixture.runtime)
        let task = Task {
            try await backend.train(
                datasetURL: fixture.root,
                outputURL: output,
                options: TrainingOptions(),
                progress: nil
            )
        }
        try await Task.sleep(for: .milliseconds(50))

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: output.appendingPathComponent(
                    TrainerProcessLease.filename
                ).path
            ))
        }
    }

    private func makeFakeRuntime(body: String) throws -> (
        root: URL,
        runtime: MsplatRuntimeLocation
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let executable = root.appendingPathComponent("msplat")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let metallib = root.appendingPathComponent("default.metallib")
        try Data("metal".utf8).write(to: metallib)
        return (
            root,
            MsplatRuntimeLocation(
                executableURL: executable,
                metallibURL: metallib,
                version: "test"
            )
        )
    }
}
