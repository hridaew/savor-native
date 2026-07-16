import AVFoundation
import CoreVideo
import Foundation
import Metal

/// Streams BGRA Metal textures into an H.264 movie, one frame at a time,
/// optionally muxing in the capture's original soundtrack (trimmed to the
/// orbit's duration and re-encoded as AAC). Frames arrive already-rendered
/// from the viewer's offscreen pass.
@MainActor
final class OrbitVideoWriter {
    enum Error: LocalizedError {
        case writerStartFailed(String)
        case pixelBufferUnavailable
        case appendFailed(String)
        case audioReadFailed(String)

        var errorDescription: String? {
            switch self {
            case let .writerStartFailed(reason):
                "Could not start the video writer: \(reason)"
            case .pixelBufferUnavailable:
                "Could not allocate a video frame buffer."
            case let .appendFailed(reason):
                "Could not append a video frame: \(reason)"
            case let .audioReadFailed(reason):
                "Could not read the capture's soundtrack: \(reason)"
            }
        }
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let audioReader: AVAssetReader?
    private let audioOutput: AVAssetReaderTrackOutput?
    private let framesPerSecond: Int
    private let width: Int
    private let height: Int

    /// `audioSourceURL` mixes in that file's audio track (first
    /// `duration` seconds). Async because the audio track has to be
    /// inspected before the writer session starts.
    static func make(
        outputURL: URL,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        audioSourceURL: URL? = nil,
        duration: Double
    ) async throws -> OrbitVideoWriter {
        var audioTrack: AVAssetTrack?
        var audioAsset: AVURLAsset?
        if let audioSourceURL {
            let asset = AVURLAsset(url: audioSourceURL)
            audioTrack = try? await asset
                .loadTracks(withMediaType: .audio).first
            audioAsset = audioTrack == nil ? nil : asset
        }
        return try OrbitVideoWriter(
            outputURL: outputURL,
            width: width,
            height: height,
            framesPerSecond: framesPerSecond,
            audioAsset: audioAsset,
            audioTrack: audioTrack,
            duration: duration
        )
    }

    private init(
        outputURL: URL,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        audioAsset: AVURLAsset?,
        audioTrack: AVAssetTrack?,
        duration: Double
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

        if let audioAsset, let audioTrack {
            let reader = try AVAssetReader(asset: audioAsset)
            reader.timeRange = CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            )
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            reader.add(output)
            let encoder = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 160_000,
                ]
            )
            encoder.expectsMediaDataInRealTime = false
            writer.add(encoder)
            audioReader = reader
            audioOutput = output
            audioInput = encoder
        } else {
            audioReader = nil
            audioOutput = nil
            audioInput = nil
        }

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
        try await pumpAudio()
        await writer.finishWriting()
        if let error = writer.error {
            throw error
        }
    }

    private func pumpAudio() async throws {
        guard let audioReader, let audioOutput, let audioInput else {
            return
        }
        guard audioReader.startReading() else {
            throw Error.audioReadFailed(
                audioReader.error?.localizedDescription ?? "unknown"
            )
        }
        while let sample = audioOutput.copyNextSampleBuffer() {
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard audioInput.append(sample) else {
                throw Error.appendFailed(
                    writer.error?.localizedDescription ?? "unknown"
                )
            }
        }
        if audioReader.status == .failed {
            throw Error.audioReadFailed(
                audioReader.error?.localizedDescription ?? "unknown"
            )
        }
        audioInput.markAsFinished()
    }
}
