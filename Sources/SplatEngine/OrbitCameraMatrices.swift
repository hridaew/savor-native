import Foundation
import simd

public enum OrbitCameraMatrices {
    public static func perspectiveProjection(
        fovYRadians: Float,
        aspectRatio: Float,
        nearZ: Float,
        farZ: Float
    ) -> simd_float4x4 {
        let yScale = 1 / tan(fovYRadians * 0.5)
        let xScale = yScale / aspectRatio
        let zScale = farZ / (nearZ - farZ)
        return simd_float4x4(
            SIMD4(xScale, 0, 0, 0),
            SIMD4(0, yScale, 0, 0),
            SIMD4(0, 0, zScale, -1),
            SIMD4(0, 0, zScale * nearZ, 0)
        )
    }

    public static func viewMatrix(
        for camera: OrbitCameraState
    ) -> simd_float4x4 {
        let eye = camera.cameraPosition
        let backward = simd_normalize(eye - camera.target)
        let right = simd_normalize(simd_cross(
            camera.verticalAxis.worldUp,
            backward
        ))
        let up = simd_cross(backward, right)
        return simd_float4x4(
            SIMD4(right.x, up.x, backward.x, 0),
            SIMD4(right.y, up.y, backward.y, 0),
            SIMD4(right.z, up.z, backward.z, 0),
            SIMD4(
                -simd_dot(right, eye),
                -simd_dot(up, eye),
                -simd_dot(backward, eye),
                1
            )
        )
    }
}
