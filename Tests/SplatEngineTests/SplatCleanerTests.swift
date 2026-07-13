import Foundation
import simd
import SplatIO
import XCTest
@testable import SplatEngine

final class SplatCleanerTests: XCTestCase {
    func testRemovesLonelyFloaterAndPreservesFullSH() throws {
        let surface = makeSurfacePoints()
        let floater = makePoint(position: SIMD3(10, 10, 10))

        let output = try SplatCleaner.cleanPoints(
            surface + [floater],
            cameraCenters: [SIMD3(0, 0, 2)]
        )

        XCTAssertEqual(output.statistics.totalCount, 28)
        XCTAssertEqual(output.statistics.floaterCount, 1)
        XCTAssertEqual(output.points.count, 27)
        XCTAssertEqual(
            output.points.first?.color.asSphericalHarmonicFloat.count,
            9
        )
        let maximumDistance = output.points
            .map { simd_length($0.position) }
            .max() ?? 0
        XCTAssertLessThanOrEqual(maximumDistance, 1.2)
    }

    func testWritesCleanedPLYTransactionallyWithoutChangingRawFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rawURL = root.appendingPathComponent("raw.ply")
        let sceneURL = root.appendingPathComponent("scene.ply")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(makeSurfacePoints(), to: rawURL)
        let rawData = try Data(contentsOf: rawURL)

        let result = try await SplatCleaner.clean(
            inputURL: rawURL,
            outputURL: sceneURL,
            cameraCenters: [SIMD3(0, 0, 2)]
        )

        XCTAssertEqual(result.keptCount, 27)
        XCTAssertEqual(try Data(contentsOf: rawURL), rawData)
        let cleaned = try await SplatPLYSceneReader(sceneURL).readAll()
        XCTAssertEqual(cleaned.count, 27)
        XCTAssertEqual(
            cleaned.first?.color.asSphericalHarmonicFloat.count,
            9
        )
        let metadata = try XCTUnwrap(SplatFramingMetadata.load(near: sceneURL))
        XCTAssertGreaterThan(metadata.compactRadius, 0)
        XCTAssertEqual(metadata.radius, 1, accuracy: 0.0001)
        XCTAssertEqual(result.compactRadius, metadata.compactRadius)
        XCTAssertNotNil(result.cameraPosition)
    }

    func testEmptyPLYFailsFastWithoutHanging() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rawURL = root.appendingPathComponent("empty.ply")
        let sceneURL = root.appendingPathComponent("scene.ply")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let header = """
        ply
        format binary_little_endian 1.0
        element vertex 0
        property float x
        property float y
        property float z
        end_header

        """
        try Data(header.utf8).write(to: rawURL)

        let started = ContinuousClock.now
        do {
            _ = try await SplatCleaner.clean(
                inputURL: rawURL,
                outputURL: sceneURL,
                cameraCenters: [SIMD3(0, 0, 2)]
            )
            XCTFail("Expected emptyInput")
        } catch SplatCleaner.Error.emptyInput {
            let elapsed = started.duration(to: .now)
            XCTAssertLessThan(elapsed, .seconds(2))
        }
    }

    func testOrbitHazeRunsWhenFloatersInflatePastCameras() throws {
        var points = makeSurfacePoints()
        // Sparse far shells inflate the measured subject radius past the
        // camera ring; the haze annulus must still run inside the cameras.
        for index in 0..<24 {
            let angle = Float(index) * (.pi / 12)
            points.append(
                makePoint(
                    position: SIMD3(2.2 * cos(angle), 0, 2.2 * sin(angle)),
                    opacity: 0.9,
                    scale: 0.02
                )
            )
        }
        // Giant haze candidates between the compact core and the cameras.
        for index in 0..<8 {
            let angle = Float(index) * (.pi / 4)
            for radial in 0..<4 {
                let radius = 0.55 + Float(radial) * 0.05
                points.append(
                    makePoint(
                        position: SIMD3(
                            radius * cos(angle),
                            0.02 * Float(radial),
                            radius * sin(angle)
                        ),
                        opacity: 0.04,
                        scale: 0.8
                    )
                )
            }
        }
        let cameras = (0..<12).map { index -> SIMD3<Float> in
            let angle = Float(index) * (.pi / 6)
            return SIMD3(cos(angle), 0.1, sin(angle))
        }

        let output = try SplatCleaner.cleanPoints(
            points,
            cameraCenters: cameras
        )

        XCTAssertGreaterThan(output.statistics.hazeRemovedCount, 0)
        XCTAssertLessThan(output.points.count, points.count)
    }

    func testIsolatesOpaqueShellForObjectCaptures() throws {
        // Dense opaque core so medianDistance tracks the subject, not the shell.
        // Large enough that plane culling cannot drop subjectIndices to the
        // all-points fallback (which would treat the shell as the subject).
        var points: [SplatPoint] = []
        for x in -7...7 {
            for y in -7...7 {
                for z in -7...7 {
                    points.append(
                        makePoint(
                            position: SIMD3(
                                Float(x) * 0.015,
                                Float(y) * 0.015,
                                Float(z) * 0.015
                            ),
                            opacity: 0.95,
                            scale: 0.02
                        )
                    )
                }
            }
        }
        let coreCount = points.count
        // Opaque densification shell outside compactRadius * 1.2 but inside
        // the camera ring — haze alone would keep these.
        for index in 0..<48 {
            let angle = Float(index) * (.pi / 24)
            for height in -2...2 {
                points.append(
                    makePoint(
                        position: SIMD3(
                            0.55 * cos(angle),
                            Float(height) * 0.03,
                            0.55 * sin(angle)
                        ),
                        opacity: 0.95,
                        scale: 0.035
                    )
                )
            }
        }
        let cameras = (0..<12).map { index -> SIMD3<Float> in
            let angle = Float(index) * (.pi / 6)
            return SIMD3(1.2 * cos(angle), 0.1, 1.2 * sin(angle))
        }

        let output = try SplatCleaner.cleanPoints(
            points,
            cameraCenters: cameras,
            configuration: SplatCleaningConfiguration(isolateSubject: true)
        )

        XCTAssertFalse(output.statistics.isEnvironment)
        XCTAssertGreaterThan(output.statistics.subjectIsolatedCount, 0)
        XCTAssertLessThan(output.points.count, points.count)
        XCTAssertLessThanOrEqual(
            output.points.count,
            coreCount
        )
        let maximumDistance = output.points
            .map { simd_length($0.position) }
            .max() ?? 0
        XCTAssertLessThanOrEqual(maximumDistance, 1.2)
    }

    func testDefaultCleanupDoesNotHardIsolateSubject() throws {
        var points = makeSurfacePoints()
        for index in 0..<16 {
            let angle = Float(index) * (.pi / 8)
            points.append(
                makePoint(
                    position: SIMD3(0.8 * cos(angle), 0, 0.8 * sin(angle)),
                    opacity: 0.95,
                    scale: 0.04
                )
            )
        }
        let cameras = (0..<8).map { index -> SIMD3<Float> in
            let angle = Float(index) * (.pi / 4)
            return SIMD3(1.5 * cos(angle), 0.1, 1.5 * sin(angle))
        }

        let output = try SplatCleaner.cleanPoints(
            points,
            cameraCenters: cameras
        )

        XCTAssertEqual(output.statistics.subjectIsolatedCount, 0)
    }

    func testSkipsHardIsolationForEnvironmentCaptures() throws {
        var points: [SplatPoint] = []
        for x in -5...5 {
            for y in -5...5 {
                for z in -5...5 {
                    points.append(
                        makePoint(
                            position: SIMD3(
                                Float(x) * 0.02,
                                Float(y) * 0.02,
                                Float(z) * 0.02
                            ),
                            opacity: 0.95,
                            scale: 0.025
                        )
                    )
                }
            }
        }
        for index in 0..<36 {
            let angle = Float(index) * (.pi / 18)
            points.append(
                makePoint(
                    position: SIMD3(
                        0.4 * cos(angle),
                        0,
                        0.4 * sin(angle)
                    ),
                    opacity: 0.95,
                    scale: 0.03
                )
            )
        }
        // Cameras sit inside the compact core → environment mode.
        let cameras = [
            SIMD3<Float>(0.02, 0.02, 0.02),
            SIMD3<Float>(-0.02, 0.02, 0.01),
            SIMD3<Float>(0.01, -0.02, 0.02),
        ]

        let withIsolation = try SplatCleaner.cleanPoints(
            points,
            cameraCenters: cameras,
            configuration: SplatCleaningConfiguration(isolateSubject: true)
        )
        let withoutIsolation = try SplatCleaner.cleanPoints(
            points,
            cameraCenters: cameras,
            configuration: SplatCleaningConfiguration(isolateSubject: false)
        )

        XCTAssertTrue(withIsolation.statistics.isEnvironment)
        XCTAssertEqual(withIsolation.statistics.subjectIsolatedCount, 0)
        XCTAssertEqual(
            withIsolation.points.count,
            withoutIsolation.points.count
        )
    }

    private func makeSurfacePoints() -> [SplatPoint] {
        (-1...1).flatMap { x in
            (-1...1).flatMap { y in
                (-1...1).map { z in
                    makePoint(position: SIMD3(
                        Float(x) * 0.02,
                        Float(y) * 0.02,
                        Float(z) * 0.02
                    ))
                }
            }
        }
    }

    private func makePoint(
        position: SIMD3<Float>,
        opacity: Float = 0.9,
        scale: Float = 0.03
    ) -> SplatPoint {
        let coefficients = (0..<9).map { index in
            SIMD3<Float>(repeating: Float(index) * 0.01)
        }
        return SplatPoint(
            position: position,
            color: .sphericalHarmonicFloat(coefficients),
            opacity: .linearFloat(opacity),
            scale: .linearFloat(SIMD3(repeating: scale)),
            rotation: simd_quatf(real: 1, imag: .zero)
        )
    }

    private func write(
        _ points: [SplatPoint],
        to url: URL
    ) async throws {
        let writer = try SplatPLYSceneWriter(toFileAtPath: url.path)
        try await writer.start(
            sphericalHarmonicDegree: 2,
            pointCount: points.count
        )
        try await writer.write(points)
        try await writer.close()
    }
}
