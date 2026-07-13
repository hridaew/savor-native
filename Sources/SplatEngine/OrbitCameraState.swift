import Foundation
import simd

public enum ViewerVerticalAxis: Sendable, Equatable {
    case yUp
    case yDown

    public var worldUp: SIMD3<Float> {
        switch self {
        case .yUp:
            SIMD3(0, 1, 0)
        case .yDown:
            SIMD3(0, -1, 0)
        }
    }
}

public struct OrbitCameraState: Sendable, Equatable {
    public private(set) var yaw: Float
    public private(set) var pitch: Float
    public private(set) var distance: Float
    public private(set) var target: SIMD3<Float>
    public private(set) var verticalAxis: ViewerVerticalAxis

    public init(
        yaw: Float = 0,
        pitch: Float = 0,
        distance: Float = 8,
        target: SIMD3<Float> = .zero,
        verticalAxis: ViewerVerticalAxis = .yUp
    ) {
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.target = target
        self.verticalAxis = verticalAxis
    }

    public mutating func orbit(
        deltaX: Float,
        deltaY: Float,
        sensitivity: Float = 0.01
    ) {
        yaw += deltaX * sensitivity
        let pitchLimit = Float.pi / 2 - 0.05
        pitch = min(
            pitchLimit,
            max(-pitchLimit, pitch + deltaY * sensitivity)
        )
    }

    public mutating func pan(
        deltaX: Float,
        deltaY: Float,
        sensitivity: Float = 0.001
    ) {
        let backward = simd_normalize(cameraPosition - target)
        let right = simd_normalize(simd_cross(verticalAxis.worldUp, backward))
        let cameraUp = simd_normalize(simd_cross(backward, right))
        let scale = distance * sensitivity
        target += right * (-deltaX * scale)
            + cameraUp * (deltaY * scale)
    }

    public mutating func zoom(
        magnification: Float,
        sensitivity: Float = 0.1
    ) {
        let adjusted = distance * exp(-magnification * sensitivity)
        distance = min(40, max(0.5, adjusted))
    }

    public mutating func fit(
        target: SIMD3<Float>,
        radius: Float,
        fovYRadians: Float
    ) {
        self.target = target
        let safeRadius = max(radius, 0.1)
        let fitDistance = safeRadius * 1.05 / tan(fovYRadians * 0.5)
        distance = min(40, max(0.5, fitDistance))
    }

    /// Place the orbit camera at an explicit position looking at `target` —
    /// used to start viewing from where the capture cameras actually were,
    /// so the scene reads the way it was filmed.
    public mutating func look(
        from position: SIMD3<Float>,
        at target: SIMD3<Float>
    ) {
        let offset = position - target
        let length = simd_length(offset)
        guard length > 0.000_001 else {
            return
        }
        self.target = target
        distance = min(40, max(0.5, length))
        let upSign: Float = verticalAxis == .yUp ? 1 : -1
        let pitchLimit = Float.pi / 2 - 0.05
        let rawPitch = asin(max(-1, min(1, upSign * offset.y / length)))
        pitch = min(pitchLimit, max(-pitchLimit, rawPitch))
        yaw = atan2(offset.x, offset.z)
    }

    public mutating func setVerticalAxis(_ verticalAxis: ViewerVerticalAxis) {
        self.verticalAxis = verticalAxis
    }

    public mutating func advanceYaw(by radians: Float) {
        yaw += radians
    }

    public var cameraPosition: SIMD3<Float> {
        let cosPitch = cos(pitch)
        let upSign = verticalAxis == .yUp ? Float(1) : -1
        return target + SIMD3(
            distance * sin(yaw) * cosPitch,
            upSign * distance * sin(pitch),
            distance * cos(yaw) * cosPitch
        )
    }
}
