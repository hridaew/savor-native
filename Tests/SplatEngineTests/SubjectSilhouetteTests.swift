import Foundation
import simd
import SplatIO
import XCTest
@testable import SplatEngine

final class SubjectSilhouetteTests: XCTestCase {
    // MARK: - Projection

    func testProjectsThroughPinholeCamera() {
        // Identity camera-to-world: camera at origin looking down −Z, +Y up.
        let view = makeView(
            cameraToWorld: matrix_identity_float4x4,
            mask: [Bool](repeating: true, count: 200 * 200)
        )

        // Straight ahead lands on the principal point (mask center).
        XCTAssertEqual(
            view.maskCellIndex(SIMD3(0, 0, -2)),
            100 * 200 + 100
        )
        // +X in front of the camera lands right of center.
        let right = view.maskCellIndex(SIMD3(0.2, 0, -2))
        XCTAssertNotNil(right)
        XCTAssertGreaterThan(right! % 200, 100)
        // +Y (up in OpenGL camera space) lands above center = smaller row.
        let up = view.maskCellIndex(SIMD3(0, 0.2, -2))
        XCTAssertNotNil(up)
        XCTAssertLessThan(up! / 200, 100)
        // Behind the camera is not seen.
        XCTAssertNil(view.maskCellIndex(SIMD3(0, 0, 2)))
        // Far outside the frustum is not seen.
        XCTAssertNil(view.maskCellIndex(SIMD3(50, 0, -2)))
    }

    func testConsensusCountsOnlyViewsThatSeeThePoint() {
        let seeing = makeView(
            cameraToWorld: matrix_identity_float4x4,
            mask: [Bool](repeating: true, count: 200 * 200)
        )
        var missMask = [Bool](repeating: false, count: 200 * 200)
        missMask[0] = true
        let rejecting = makeView(
            cameraToWorld: matrix_identity_float4x4,
            mask: missMask
        )
        // Camera looking away: the point is behind it.
        let blind = makeView(
            cameraToWorld: lookAt(
                eye: SIMD3(0, 0, -4),
                target: SIMD3(0, 0, -8)
            ),
            mask: [Bool](repeating: true, count: 200 * 200)
        )
        let silhouettes = SubjectSilhouettes(
            views: [seeing, rejecting, blind]
        )

        let verdict = silhouettes.consensus(for: SIMD3(0, 0, -2))

        XCTAssertEqual(verdict.seenBy, 2)
        XCTAssertEqual(verdict.ratio, 0.5, accuracy: 0.001)
    }

    func testDilationExpandsMaskByOnePixel() {
        var mask = [Bool](repeating: false, count: 25)
        mask[2 * 5 + 2] = true

        let dilated = SubjectMaskGenerator.dilated(mask, width: 5, height: 5)

        XCTAssertTrue(dilated[2 * 5 + 1])
        XCTAssertTrue(dilated[2 * 5 + 3])
        XCTAssertTrue(dilated[1 * 5 + 2])
        XCTAssertTrue(dilated[3 * 5 + 2])
        XCTAssertFalse(dilated[0])
    }

    // MARK: - Cleaner integration

    /// The case geometry cannot solve: a blob *touching* the subject (same
    /// connected component, same density) that is not part of it — a
    /// pedestal edge, a shadow, fog off the surface. Silhouette consensus
    /// removes it because side views see it outside the subject's outline.
    func testHullRemovesAttachedOffSilhouetteBlob() throws {
        var points = makeDenseBlob(center: .zero, half: 2)
        let subjectCount = points.count
        // Attached: gap 0.08 with 0.03-scale splats — connected at the
        // cleaner's voxel resolution, and inside the camera orbit.
        points += makeDenseBlob(center: SIMD3(0.12, 0, 0), half: 2)
        let cameras = ring(radius: 1.1)
        let silhouettes = SubjectSilhouettes(views: cameras.map { eye in
            silhouetteView(
                eye: eye,
                subjectPoints: Array(points.prefix(subjectCount))
            )
        })

        let output = try SplatCleaner.cleanPoints(
            points.map(makePoint),
            cameraCenters: cameras,
            silhouettes: silhouettes,
            configuration: SplatCleaningConfiguration(maskMinimumViews: 4)
        )

        // The attached blob is gone; the subject survives intact.
        XCTAssertLessThanOrEqual(output.points.count, subjectCount)
        XCTAssertGreaterThan(
            output.points.count,
            Int(Double(subjectCount) * 0.9)
        )
        XCTAssertGreaterThan(output.statistics.subjectIsolatedCount, 0)
    }

    /// Masks that miss the subject entirely (bad segmentation) must not
    /// hollow out the capture — the hull is discarded, geometry passes run.
    func testHullFallsBackWhenMasksMissEverything() throws {
        let points = makeDenseBlob(center: .zero, half: 2)
        let cameras = ring(radius: 1.1)
        let silhouettes = SubjectSilhouettes(views: cameras.map { eye in
            makeView(
                cameraToWorld: lookAt(eye: eye, target: .zero),
                mask: [Bool](repeating: false, count: 200 * 200)
            )
        })

        let output = try SplatCleaner.cleanPoints(
            points.map(makePoint),
            cameraCenters: cameras,
            silhouettes: silhouettes,
            configuration: SplatCleaningConfiguration(maskMinimumViews: 4)
        )

        XCTAssertGreaterThan(
            output.points.count,
            Int(Double(points.count) * 0.9)
        )
    }

    // MARK: - Helpers

    /// A silhouette view whose mask is exactly the projection of the given
    /// subject points (plus one dilation) — a synthetic "perfect" Vision
    /// mask.
    private func silhouetteView(
        eye: SIMD3<Float>,
        subjectPoints: [SIMD3<Float>]
    ) -> SubjectSilhouettes.View {
        let allTrue = makeView(
            cameraToWorld: lookAt(eye: eye, target: .zero),
            mask: [Bool](repeating: true, count: 200 * 200)
        )
        var mask = [Bool](repeating: false, count: 200 * 200)
        for point in subjectPoints {
            if let index = allTrue.maskCellIndex(point) {
                mask[index] = true
            }
        }
        mask = SubjectMaskGenerator.dilated(mask, width: 200, height: 200)
        return makeView(
            cameraToWorld: lookAt(eye: eye, target: .zero),
            mask: mask
        )
    }

    private func makeView(
        cameraToWorld: simd_float4x4,
        mask: [Bool]
    ) -> SubjectSilhouettes.View {
        SubjectSilhouettes.View(
            worldToCamera: cameraToWorld.inverse,
            focalLengthX: 300,
            focalLengthY: 300,
            principalPointX: 100,
            principalPointY: 100,
            imageWidth: 200,
            imageHeight: 200,
            mask: mask,
            maskWidth: 200,
            maskHeight: 200
        )
    }

    /// OpenGL-convention camera-to-world: camera at `eye` looking at
    /// `target`, +Y up, camera looks down its −Z.
    private func lookAt(
        eye: SIMD3<Float>,
        target: SIMD3<Float>,
        up: SIMD3<Float> = SIMD3(0, 1, 0)
    ) -> simd_float4x4 {
        let backward = simd_normalize(eye - target)
        var right = simd_cross(up, backward)
        if simd_length(right) < 0.0001 {
            right = simd_cross(SIMD3(1, 0, 0), backward)
        }
        right = simd_normalize(right)
        let cameraUp = simd_cross(backward, right)
        return simd_float4x4(
            SIMD4(right, 0),
            SIMD4(cameraUp, 0),
            SIMD4(backward, 0),
            SIMD4(eye, 1)
        )
    }

    private func ring(radius: Float, count: Int = 12) -> [SIMD3<Float>] {
        (0..<count).map { index in
            let angle = Float(index) * 2 * .pi / Float(count)
            return SIMD3(
                radius * cos(angle),
                0.05,
                radius * sin(angle)
            )
        }
    }

    private func makeDenseBlob(
        center: SIMD3<Float>,
        half: Int
    ) -> [SIMD3<Float>] {
        var blob: [SIMD3<Float>] = []
        for x in -half...half {
            for y in -half...half {
                for z in -half...half {
                    blob.append(center + SIMD3(
                        Float(x) * 0.02,
                        Float(y) * 0.02,
                        Float(z) * 0.02
                    ))
                }
            }
        }
        return blob
    }

    private func makePoint(position: SIMD3<Float>) -> SplatPoint {
        let coefficients = (0..<9).map { index in
            SIMD3<Float>(repeating: Float(index) * 0.01)
        }
        return SplatPoint(
            position: position,
            color: .sphericalHarmonicFloat(coefficients),
            opacity: .linearFloat(0.9),
            scale: .linearFloat(SIMD3(repeating: 0.03)),
            rotation: simd_quatf(real: 1, imag: .zero)
        )
    }
}
