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

    /// A dense blob near the orbit center and a separate dense blob offset
    /// toward the ring: isolation must keep the connected subject and drop the
    /// disconnected background (which is what "distant splats placed at the
    /// wrong depth" look like). Uses the default config to confirm isolation
    /// is on by default for object captures.
    func testIsolatesDisconnectedBackground() throws {
        // Dense, overlapping splats (spacing ≤ scale) so the floater pass keeps
        // them — the cleaner's grid is tuned for real splat densities. Kept
        // under 300 points total so no support plane is fitted (this test
        // targets connectivity, not plane logic).
        var points = makeDenseBlob(center: SIMD3(0, 0, 0), half: 2)
        let subjectCount = points.count
        // Disconnected background blob offset toward the camera ring.
        points += makeDenseBlob(center: SIMD3(0.6, 0, 0), half: 2)
        let cameras = (0..<12).map { index -> SIMD3<Float> in
            let angle = Float(index) * (.pi / 6)
            return SIMD3(1.1 * cos(angle), 0.05, 1.1 * sin(angle))
        }

        let output = try SplatCleaner.cleanPoints(points, cameraCenters: cameras)

        XCTAssertFalse(output.statistics.isEnvironment)
        XCTAssertGreaterThan(output.statistics.subjectIsolatedCount, 0)
        // The far background blob (raw x ≈ 0.6) must be gone; the subject stays.
        // Compare against the normalized subject centroid to avoid CRS coupling.
        let keptCount = output.points.count
        XCTAssertGreaterThan(keptCount, subjectCount / 2)
        XCTAssertLessThan(keptCount, subjectCount + 20)
    }

    /// Anti-amputation guard: a thin arm extending off the core must be kept,
    /// because it is voxel-connected to the subject. The old radial crop
    /// dropped exactly these thin extremities (e.g. legs).
    func testKeepsThinAttachedExtremities() throws {
        let core = makeDenseBlob(center: SIMD3(0, 0, 0), half: 2)
        var points = core
        // Thin arm: a dense 3×3 column reaching out in +x, contiguous with the
        // core, ending far from it. Its far end must survive isolation.
        var armCount = 0
        for step in 1...9 {
            for a in -1...1 {
                for b in -1...1 {
                    points.append(makePoint(position: SIMD3(
                        0.04 + Float(step) * 0.02,
                        Float(a) * 0.02,
                        Float(b) * 0.02
                    )))
                    armCount += 1
                }
            }
        }
        let cameras = (0..<12).map { index -> SIMD3<Float> in
            let angle = Float(index) * (.pi / 6)
            return SIMD3(1.0 * cos(angle), 0.05, 1.0 * sin(angle))
        }

        let output = try SplatCleaner.cleanPoints(points, cameraCenters: cameras)

        // If the arm were amputated only the core (~125) would survive; keeping
        // connectivity means most of core+arm stays.
        XCTAssertGreaterThan(
            output.points.count,
            core.count + armCount / 2,
            "thin attached arm was amputated"
        )
    }

    /// Regression for the "cut in half" bug: a tall figure standing through a
    /// horizontal floor sheet. The support plane sits at the figure's mid
    /// height, but the lower body must survive (its column has the torso above
    /// it) while the floor sheet's outer extent is trimmed.
    func testDoesNotAmputateLowerBodyThroughSupportPlane() throws {
        var points: [SplatPoint] = []
        // Wide, dense horizontal floor sheet at y = 0 (triggers plane RANSAC).
        for x in -12...12 {
            for z in -12...12 {
                points.append(makePoint(position: SIMD3(
                    Float(x) * 0.02, 0, Float(z) * 0.02
                )))
            }
        }
        // Tall figure through the sheet: a 3×3 column spanning y ∈ [-0.16, 0.16].
        var lowerBodyCount = 0
        for yi in -8...8 {
            for a in -1...1 {
                for b in -1...1 {
                    let y = Float(yi) * 0.02
                    points.append(makePoint(position: SIMD3(
                        Float(a) * 0.02, y, Float(b) * 0.02
                    )))
                    if y < -0.02 { lowerBodyCount += 1 }
                }
            }
        }
        let cameras = (0..<16).map { index -> SIMD3<Float> in
            let angle = Float(index) * (.pi / 8)
            return SIMD3(0.9 * cos(angle), 0.1, 0.9 * sin(angle))
        }

        let output = try SplatCleaner.cleanPoints(points, cameraCenters: cameras)

        // The lower body (y < 0, under the torso) must survive. Positions are
        // normalized but the figure is centered near the origin, so lower-body
        // points stay negative-y.
        let keptLowerBody = output.points.filter { $0.position.y < -0.02 }.count
        XCTAssertGreaterThan(
            keptLowerBody,
            lowerBodyCount / 2,
            "lower body amputated at the support plane"
        )
        // The 625-point floor sheet (no body above its outer parts) must be
        // largely trimmed — the figure (~153 points) plus a small base is well
        // under the untrimmed total.
        XCTAssertLessThan(
            output.points.count,
            400,
            "distant floor sheet not trimmed"
        )
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

    /// Dense overlapping blob (spacing 0.02 ≤ splat scale 0.03) so the floater
    /// pass keeps it — mirrors real splat density. `half` sets the half-extent
    /// in voxels: half=2 → a 5×5×5 = 125-point blob.
    private func makeDenseBlob(
        center: SIMD3<Float>,
        half: Int
    ) -> [SplatPoint] {
        var blob: [SplatPoint] = []
        for x in -half...half {
            for y in -half...half {
                for z in -half...half {
                    blob.append(makePoint(position: center + SIMD3(
                        Float(x) * 0.02,
                        Float(y) * 0.02,
                        Float(z) * 0.02
                    )))
                }
            }
        }
        return blob
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
