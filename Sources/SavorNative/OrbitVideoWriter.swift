import AVFoundation
import CoreVideo
import Foundation
import Metal

/// Streams BGRA Metal textures into an H.264 movie, one frame at a time.
/// Frames arrive already-rendered from the viewer's offscreen pass.
@MainActor
final class OrbitVideoWriter {
    enum Error: LocalizedError {
        case writerStartFailed(String)
        case pixelBufferUnavailable
        case appendFailed(String)

        var errorDescription: String? {
            switch self {
            case let .writerStartFailed(reason):
                "Could not start the video writer: \(reason)"
            case .pixelBufferUnavailable:
                "Could not allocate a video frame buffer."
            case let .appendFailed(reason):
                "Could not append a video frame: \(reason)"
            }
        }
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let framesPerSecond: Int
    private let width: Int
    private let height: Int

    init(
        outputURL: URL,
        width: Int,
        height: Int,
        framesPerSecond: Int
    ) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 20_000_000,
                    AVVideoProfileLevelKey:
                        AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw Error.writerStartFailed(
                writer.error?.localizedDescription ?? "unknown"
            )
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(texture: MTLTexture, frameIndex: Int) async throws {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw Error.pixelBufferUnavailable
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else {
            throw Error.pixelBufferUnavailable
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw Error.pixelBufferUnavailable
        }
        texture.getBytes(
            base,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        let time = CMTime(
            value: CMTimeValue(frameIndex),
            timescale: CMTimeScale(framesPerSecond)
        )
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            throw Error.appendFailed(
                writer.error?.localizedDescription ?? "unknown"
            )
        }
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error {
            throw error
        }
    }
}
