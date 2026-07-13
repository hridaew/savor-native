import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalSplatter
import simd
import SplatEngine
import SplatIO
import UniformTypeIdentifiers

@main
enum Phase2Snapshot {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count >= 2 else {
                throw SnapshotError.invalidArguments
            }
            let inputURL = URL(fileURLWithPath: arguments[0])
            let outputURL = URL(fileURLWithPath: arguments[1])
            let verticalAxis: ViewerVerticalAxis = arguments.contains(
                "--y-down"
            ) ? .yDown : .yUp
            let cameraPose = try parseCameraPose(arguments)
            let cameraFitURL = parseCameraFitURL(arguments)
            try await render(
                inputURL: inputURL,
                outputURL: outputURL,
                verticalAxis: verticalAxis,
                cameraPose: cameraPose,
                cameraFitURL: cameraFitURL
            )
            print(outputURL.path)
        } catch {
            FileHandle.standardError.write(
                Data("phase2-snapshot: \(error.localizedDescription)\n".utf8)
            )
            Foundation.exit(1)
        }
    }

    private static func render(
        inputURL: URL,
        outputURL: URL,
        verticalAxis: ViewerVerticalAxis,
        cameraPose: CameraPose?,
        cameraFitURL: URL?
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SnapshotError.metalUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw SnapshotError.commandQueueUnavailable
        }
        let points = try await AutodetectSceneReader(inputURL).readAll()
        let scales = points.map { point -> Float in
            let scale = point.scale.asLinearFloat
            return max(scale.x, max(scale.y, scale.z))
        }
        let metadata = SplatFramingMetadata.load(near: inputURL)
        let framing = try SplatSceneFramingResolver.resolve(
            positions: points.map(\.position),
            opacities: points.map(\.opacity.asLinearFloat),
            maxLinearScales: scales,
            metadata: metadata,
            transformsURL: cameraFitURL
                ?? TransformsCameraCenters.resolveTransformsURL(near: inputURL)
        )
        let displayPoints = SplatDisplayCulling.filterForDisplay(
            points: points,
            compactRadius: metadata?.compactRadius,
            framingRadius: framing.radius
        )

        let width: Int
        let height: Int
        let projectionMatrix: simd_float4x4
        let viewMatrix: simd_float4x4
        let nearZ: Float
        let farZ: Float
        if let cameraPose {
            width = cameraPose.width
            height = cameraPose.height
            nearZ = max(0.005, framing.radius * 0.005)
            farZ = max(100, framing.radius * 20)
            projectionMatrix = cameraPose.projectionMatrix(
                nearZ: nearZ,
                farZ: farZ
            )
            viewMatrix = cameraPose.viewMatrix
        } else {
            width = 1_200
            height = 800
            var camera = OrbitCameraState(verticalAxis: verticalAxis)
            camera.fit(
                target: framing.center,
                radius: framing.radius,
                fovYRadians: 65 * .pi / 180
            )
            nearZ = max(0.005, framing.radius * 0.005)
            farZ = max(100, camera.distance + framing.radius * 6)
            projectionMatrix = OrbitCameraMatrices.perspectiveProjection(
                fovYRadians: 65 * .pi / 180,
                aspectRatio: Float(width) / Float(height),
                nearZ: nearZ,
                farZ: farZ
            )
            viewMatrix = OrbitCameraMatrices.viewMatrix(for: camera)
        }
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared
        guard let colorTexture = device.makeTexture(
            descriptor: colorDescriptor
        ) else {
            throw SnapshotError.textureUnavailable
        }
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        guard let depthTexture = device.makeTexture(
            descriptor: depthDescriptor
        ) else {
            throw SnapshotError.textureUnavailable
        }

        let renderer = try SplatRenderer(
            device: device,
            colorFormat: .bgra8Unorm,
            depthFormat: .depth32Float,
            sampleCount: 1,
            maxViewCount: 1,
            maxSimultaneousRenders: 1,
            clearColor: MTLClearColor(
                red: 0.035,
                green: 0.043,
                blue: 0.055,
                alpha: 1
            )
        )
        try await renderer.addChunk(SplatChunk(device: device, from: displayPoints))
        let viewport = SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(width),
                height: Double(height),
                znear: 0,
                zfar: 1
            ),
            projectionMatrix: projectionMatrix,
            viewMatrix: viewMatrix,
            screenSize: SIMD2(width, height)
        )

        var rendered = false
        for _ in 0..<20 where !rendered {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw SnapshotError.commandBufferUnavailable
            }
            rendered = try renderer.render(
                viewports: [viewport],
                colorTexture: colorTexture,
                colorStoreAction: .store,
                depthTexture: depthTexture,
                rasterizationRateMap: nil,
                renderTargetArrayLength: 0,
                sortTimeout: 1,
                to: commandBuffer
            )
            if rendered {
                commandBuffer.commit()
                await commandBuffer.completed()
                guard commandBuffer.status == .completed else {
                    throw commandBuffer.error
                        ?? SnapshotError.commandBufferUnavailable
                }
            } else {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        guard rendered else {
            throw SnapshotError.rendererNotReady
        }
        try writePNG(
            texture: colorTexture,
            width: width,
            height: height,
            outputURL: outputURL
        )
    }

    private static func writePNG(
        texture: MTLTexture,
        width: Int,
        height: Int,
        outputURL: URL
    ) throws {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        guard
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                ).union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            ),
            let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw SnapshotError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SnapshotError.imageEncodingFailed
        }
    }
}

private func parseCameraFitURL(_ arguments: [String]) -> URL? {
    guard let flagIndex = arguments.firstIndex(of: "--camera-fit"),
          flagIndex + 1 < arguments.count
    else {
        return nil
    }
    return URL(fileURLWithPath: arguments[flagIndex + 1])
}

private struct CameraPose {
    let width: Int
    let height: Int
    let focalY: Float
    let viewMatrix: simd_float4x4

    func projectionMatrix(nearZ: Float, farZ: Float) -> simd_float4x4 {
        let aspectRatio = Float(width) / Float(height)
        let fovYRadians = 2 * atan(Float(height) / (2 * focalY))
        return OrbitCameraMatrices.perspectiveProjection(
            fovYRadians: fovYRadians,
            aspectRatio: aspectRatio,
            nearZ: nearZ,
            farZ: farZ
        )
    }
}

private func parseCameraPose(_ arguments: [String]) throws -> CameraPose? {
    guard let flagIndex = arguments.firstIndex(of: "--transforms"),
          flagIndex + 1 < arguments.count
    else {
        return nil
    }
    let transformsURL = URL(fileURLWithPath: arguments[flagIndex + 1])
    let frameIndex: Int
    if let indexFlag = arguments.firstIndex(of: "--frame"),
       indexFlag + 1 < arguments.count,
       let parsed = Int(arguments[indexFlag + 1]) {
        frameIndex = parsed
    } else {
        frameIndex = 0
    }
    let data = try Data(contentsOf: transformsURL)
    let payload = try JSONDecoder().decode(TransformsFile.self, from: data)
    guard payload.frames.indices.contains(frameIndex) else {
        throw SnapshotError.invalidArguments
    }
    let frame = payload.frames[frameIndex]
    guard frame.transformMatrix.count == 4,
          frame.transformMatrix.allSatisfy({ $0.count == 4 })
    else {
        throw SnapshotError.invalidArguments
    }
    var columns = [SIMD4<Float>]()
    for column in 0..<4 {
        columns.append(
            SIMD4(
                Float(frame.transformMatrix[0][column]),
                Float(frame.transformMatrix[1][column]),
                Float(frame.transformMatrix[2][column]),
                Float(frame.transformMatrix[3][column])
            )
        )
    }
    let cameraToWorld = simd_float4x4(
        columns[0],
        columns[1],
        columns[2],
        columns[3]
    )
    return CameraPose(
        width: frame.width,
        height: frame.height,
        focalY: Float(frame.focalLengthY),
        viewMatrix: cameraToWorld.inverse
    )
}

private struct TransformsFile: Decodable {
    let frames: [TransformsFrame]
}

private struct TransformsFrame: Decodable {
    let width: Int
    let height: Int
    let focalLengthY: Double
    let transformMatrix: [[Double]]

    enum CodingKeys: String, CodingKey {
        case width = "w"
        case height = "h"
        case focalLengthY = "fl_y"
        case transformMatrix = "transform_matrix"
    }
}

private enum SnapshotError: LocalizedError {
    case invalidArguments
    case metalUnavailable
    case commandQueueUnavailable
    case textureUnavailable
    case commandBufferUnavailable
    case rendererNotReady
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: phase2-snapshot INPUT.ply OUTPUT.png [--y-down] "
                + "[--transforms transforms.json] [--frame N] "
                + "[--camera-fit transforms.json]"
        case .metalUnavailable:
            "Metal is unavailable."
        case .commandQueueUnavailable:
            "Could not create a Metal command queue."
        case .textureUnavailable:
            "Could not allocate the snapshot texture."
        case .commandBufferUnavailable:
            "Could not create a Metal command buffer."
        case .rendererNotReady:
            "The splat renderer did not become ready."
        case .imageEncodingFailed:
            "Could not encode the PNG snapshot."
        }
    }
}
