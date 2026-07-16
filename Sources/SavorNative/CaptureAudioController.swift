import AVFoundation
import Combine
import Foundation

/// Loops the capture's original soundtrack under the splat viewer.
/// Playback volume is normalized once per video via an RMS scan of the audio
/// track, so quiet phone recordings and loud ones land at the same level.
@MainActor
final class CaptureAudioController: ObservableObject {
    @Published var isPlaying = false {
        didSet {
            applyPlayback()
        }
    }

    @Published var volume: Double = 0.7 {
        didSet {
            applyVolume()
        }
    }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var loadedURL: URL?
    private var normalizationGain: Float = 1
    private var analysisTask: Task<Void, Never>?

    /// Perceived-loudness target for the normalization scan (~-15 dBFS RMS).
    private static let targetRMS: Float = 0.18

    func prepare(videoURL: URL) {
        guard videoURL != loadedURL else {
            return
        }
        stop()
        loadedURL = videoURL
    }

    func stop() {
        analysisTask?.cancel()
        analysisTask = nil
        player?.pause()
        looper = nil
        player = nil
        loadedURL = nil
        isPlaying = false
    }

    private func applyPlayback() {
        guard isPlaying else {
            player?.pause()
            return
        }
        guard let loadedURL else {
            isPlaying = false
            return
        }
        if player == nil {
            let item = AVPlayerItem(url: loadedURL)
            let queue = AVQueuePlayer()
            queue.volume = 0
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            analysisTask = Task { [weak self] in
                let gain = await Self.normalizationGain(for: loadedURL)
                guard let self, !Task.isCancelled else {
                    return
                }
                normalizationGain = gain
                applyVolume()
            }
        }
        applyVolume()
        player?.play()
    }

    private func applyVolume() {
        player?.volume = normalizationGain * Float(volume)
    }

    /// RMS scan of (up to) the first 30 seconds of the audio track.
    /// AVPlayer volume cannot exceed 1, so normalization only attenuates —
    /// a whisper-quiet track stays quiet rather than clipping.
    private static func normalizationGain(for url: URL) async -> Float {
        let asset = AVURLAsset(url: url)
        guard
            let track = try? await asset.loadTracks(withMediaType: .audio)
                .first,
            let reader = try? AVAssetReader(asset: asset)
        else {
            return 1
        }
        reader.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 30, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        reader.add(output)
        guard reader.startReading() else {
            return 1
        }
        var sumOfSquares: Double = 0
        var sampleCount = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard
                let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
            else {
                continue
            }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer else {
                continue
            }
            pointer.withMemoryRebound(
                to: Float.self,
                capacity: length / MemoryLayout<Float>.size
            ) { samples in
                let count = length / MemoryLayout<Float>.size
                for index in 0..<count {
                    let sample = Double(samples[index])
                    sumOfSquares += sample * sample
                }
                sampleCount += count
            }
        }
        guard sampleCount > 0 else {
            return 1
        }
        let rms = Float((sumOfSquares / Double(sampleCount)).squareRoot())
        guard rms > 0.0001 else {
            return 1
        }
        return min(1, targetRMS / rms)
    }
}
