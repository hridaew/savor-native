import AVFoundation
import Foundation

/// One decode pass over the video scoring every frame's sharpness, so
/// extraction can keep the crispest frame per time window instead of
/// whatever uniform sampling lands on. Handheld capture video is full of
/// motion blur; blurred frames degrade both pose estimation and training.
/// Mirrors the original app's ffmpeg Sobel pass (mean edge magnitude).
enum FrameSharpnessScorer {
    struct ScoredFrame: Sendable, Equatable {
        let seconds: Double
        let score: Double
    }

    /// Decodes to 4:2:0 and reads the luma plane directly; the score is the
    /// mean absolute horizontal+vertical gradient over a subsampled grid.
    /// Returns frames in presentation order. Throws only on reader setup
    /// failure — a mid-stream decode failure returns the frames scored so
    /// far (extraction falls back to window midpoints for the rest).
    static func scores(
        asset: AVURLAsset,
        track: AVAssetTrack
    ) async throws -> [ScoredFrame] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AVError(.operationNotAllowed)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? AVError(.unknown)
        }
        defer { reader.cancelReading() }

        var scored: [ScoredFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }
            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard seconds.isFinite else {
                continue
            }
            scored.append(ScoredFrame(
                seconds: seconds,
                score: score(pixelBuffer)
            ))
        }
        return scored
    }

    static func score(_ pixelBuffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        ) == kCVReturnSuccess else {
            return 0
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        guard
            CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
            let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        else {
            return 0
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 2, height > 2 else {
            return 0
        }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        // ~480 samples across the long edge regardless of source resolution,
        // matching the original's 480px scoring pass.
        let step = max(1, max(width, height) / 480)
        var total = 0
        var count = 0
        var y = step
        while y < height - step {
            var x = step
            let row = y * stride
            let rowBelow = (y + step) * stride
            while x < width - step {
                let center = Int(luma[row + x])
                let right = Int(luma[row + x + step])
                let below = Int(luma[rowBelow + x])
                total += abs(right - center) + abs(below - center)
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else {
            return 0
        }
        return Double(total) / Double(count)
    }
}

/// Pure per-window argmax selection over scored frames.
enum SharpestFrameSelector {
    /// Splits `duration` into `windowCount` equal windows and returns one
    /// timestamp per window: the sharpest scored frame inside it, or the
    /// window midpoint when no scored frame landed there.
    static func times(
        windowCount: Int,
        duration: Double,
        scored: [FrameSharpnessScorer.ScoredFrame]
    ) -> [Double] {
        guard windowCount > 0, duration > 0 else {
            return []
        }
        let interval = duration / Double(windowCount)
        var best = [FrameSharpnessScorer.ScoredFrame?](
            repeating: nil,
            count: windowCount
        )
        for frame in scored {
            guard frame.seconds >= 0, frame.seconds < duration else {
                continue
            }
            let index = min(
                windowCount - 1,
                Int(frame.seconds / interval)
            )
            if let current = best[index], current.score >= frame.score {
                continue
            }
            best[index] = frame
        }
        return best.enumerated().map { index, frame in
            frame?.seconds ?? (Double(index) + 0.5) * interval
        }
    }
}
