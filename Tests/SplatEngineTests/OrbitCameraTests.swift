import XCTest
import simd
import SplatIO
@testable import SplatEngine

final class OrbitCameraTests: XCTestCase {
    func testOrbitClampsPitchAwayFromPoles() {
        var camera = OrbitCameraState()

        camera.orbit(deltaX: 0, deltaY: 10_000)

        XCTAssertLessThan(camera.pitch, .pi / 2)
        XCTAssertGreaterThan(camera.pitch, -.pi / 2)
    }

    func testZoomClampsCameraDistance() {
        var camera = OrbitCameraState(distance: 8)

        camera.zoom(magnification: 100)
        XCTAssertEqual(camera.distance, 0.5)

        camera.zoom(magnification: -100)
        XCTAssertEqual(camera.distance, 40)
    }

    func testViewMatrixUsesRealityKitYUpOrientation() {
        let matrix = OrbitCameraMatrices.viewMatrix(
            for: OrbitCameraState(distance: 8)
        )

        XCTAssertEqual(matrix.columns.0.x, 1, accuracy: 0.0001)
        XCTAssertEqual(matrix.columns.1.y, 1, accuracy: 0.0001)
        XCTAssertEqual(matrix.columns.3.z, -8, accuracy: 0.0001)
    }

    func testViewMatrixCanDisplayLegacyYDownSplat() {
        let matrix = OrbitCameraMatrices.viewMatrix(
            for: OrbitCameraState(
                distance: 8,
                verticalAxis: .yDown
            )
        )

        XCTAssertEqual(matrix.columns.0.x, -1, accuracy: 0.0001)
        XCTAssertEqual(matrix.columns.1.y, -1, accuracy: 0.0001)
        XCTAssertEqual(matrix.columns.3.z, -8, accuracy: 0.0001)
    }

    func testViewMatrixOrbitsAroundTarget() {
        let matrix = OrbitCameraMatrices.viewMatrix(
            for: OrbitCameraState(
                distance: 8,
                target: SIMD3(2, 3, 4)
            )
        )

        XCTAssertEqual(matrix.columns.3.x, -2, accuracy: 0.0001)
        XCTAssertEqual(matrix.columns.3.y, -3, accuracy: 0.0001)
        XCTAssertEqual(matrix.columns.3.z, -12, accuracy: 0.0001)
    }

    func testPanMovesOrbitTargetInViewPlane() {
        var camera = OrbitCameraState(distance: 10)

        camera.pan(deltaX: 100, deltaY: 50)

        XCTAssertNotEqual(camera.target, .zero)
        XCTAssertEqual(camera.target.z, 0, accuracy: 0.0001)
    }

    func testFitFramesRobustSceneRadius() {
        var camera = OrbitCameraState(distance: 8)

        camera.fit(
            target: SIMD3(1, 2, 3),
            radius: 2,
            fovYRadians: .pi / 2
        )

        XCTAssertEqual(camera.target, SIMD3(1, 2, 3))
        XCTAssertEqual(camera.distance, 2.1, accuracy: 0.0001)
    }

    func testSceneFramingPrefersCompactMetadataOverOpaqueShell() throws {
        let metadata = SplatFramingMetadata(
            compactRadius: 0.4,
            orbitRadius: 1.5,
            radius: 1,
            cameraPosition: SIMD3(0, 0.2, 1.5),
            isEnvironment: false
        )
        let framing = try SplatSceneFraming(cleanedMetadata: metadata)

        XCTAssertEqual(framing.center, .zero)
        XCTAssertEqual(framing.radius, 0.38, accuracy: 0.0001)
    }

    func testSceneFramingResolverUsesMetadataWhenPresent() throws {
        let shell = (0..<40).map { index -> SIMD3<Float> in
            let angle = Float(index) * 2 * .pi / 40
            return SIMD3(3 * cos(angle), 0, 3 * sin(angle))
        }
        let metadata = SplatFramingMetadata(
            compactRadius: 0.5,
            orbitRadius: 2,
            radius: 1,
            cameraPosition: nil,
            isEnvironment: false
        )
        let framing = try SplatSceneFramingResolver.resolve(
            positions: shell,
            opacities: Array(repeating: 0.9, count: shell.count),
            maxLinearScales: Array(repeating: 0.02, count: shell.count),
            metadata: metadata,
            transformsURL: nil
        )

        XCTAssertEqual(framing.center, .zero)
        XCTAssertLessThan(framing.radius, 0.5)
    }

    func testDisplayCullingRemovesOuterHazeLikePoints() {
        var points: [SplatPoint] = []
        for index in 0..<20 {
            let angle = Float(index) * 2 * .pi / 20
            points.append(
                SplatPoint(
                    position: SIMD3(0.3 * cos(angle), 0, 0.3 * sin(angle)),
                    color: .sphericalHarmonicFloat([SIMD3(1, 1, 1)]),
                    opacity: .linearFloat(0.9),
                    scale: .linearFloat(SIMD3(repeating: 0.02)),
                    rotation: simd_quatf(real: 1, imag: .zero)
                )
            )
        }
        points.append(
            SplatPoint(
                position: SIMD3(2, 0, 0),
                color: .sphericalHarmonicFloat([SIMD3(1, 1, 1)]),
                opacity: .linearFloat(0.05),
                scale: .linearFloat(SIMD3(repeating: 0.2)),
                rotation: simd_quatf(real: 1, imag: .zero)
            )
        )

        let filtered = SplatDisplayCulling.filterForDisplay(
            points: points,
            compactRadius: 0.4,
            framingRadius: 0.4
        )

        XCTAssertEqual(filtered.count, 20)
    }

    func testSceneFramingIgnoresSparseFarOutlier() throws {
        let ring = (0..<100).map { index in
            let angle = Float(index) * 2 * .pi / 100
            return SIMD3(cos(angle), sin(angle), 0)
        }
        let framing = try SplatSceneFraming(
            positions: ring + [SIMD3(1_000, 1_000, 1_000)]
        )

        XCTAssertLessThan(simd_length(framing.center), 0.1)
        XCTAssertGreaterThan(framing.radius, 0.9)
        XCTAssertLessThan(framing.radius, 2)
    }

    func testSceneFramingPrefersOpaqueCoreOverTransparentShell() throws {
        let core = (0..<80).map { index -> SIMD3<Float> in
            let angle = Float(index) * 2 * .pi / 80
            return SIMD3(0.2 * cos(angle), 0.2 * sin(angle), 0)
        }
        let shell = (0..<80).map { index -> SIMD3<Float> in
            let angle = Float(index) * 2 * .pi / 80
            return SIMD3(3 * cos(angle), 3 * sin(angle), 0)
        }
        let framing = try SplatSceneFraming(
            positions: core + shell,
            opacities: Array(repeating: 0.9, count: core.count)
                + Array(repeating: 0.02, count: shell.count),
            minimumOpacity: 0.15,
            radiusPercentile: 0.85
        )

        XCTAssertLessThan(simd_length(framing.center), 0.1)
        XCTAssertLessThan(framing.radius, 0.6)
    }

    func testSceneFramingUsesCameraRingWhenAvailable() throws {
        let cameras = (0..<36).map { index -> SIMD3<Float> in
            let angle = Float(index) * 2 * .pi / 36
            return SIMD3(2 * cos(angle), 0.5, 2 * sin(angle))
        }
        let framing = try SplatSceneFraming(
            cameraCenters: cameras,
            subjectHint: SIMD3(0, 0.5, 0)
        )

        XCTAssertEqual(framing.center.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(framing.radius, 1.7, accuracy: 0.05)
    }

    func testPerspectiveProjectionUsesViewportAspectRatio() {
        let matrix = OrbitCameraMatrices.perspectiveProjection(
            fovYRadians: .pi / 2,
            aspectRatio: 2,
            nearZ: 0.1,
            farZ: 100
        )

        XCTAssertEqual(matrix.columns.0.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(matrix.columns.1.y, 1, accuracy: 0.0001)
        XCTAssertEqual(matrix.columns.2.w, -1, accuracy: 0.0001)
    }
}
