import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct FrameExtractionOptions: Sendable, Equatable {
    public let targetFrameCount: Int
    public let maxLongEdge: Int
    public let jpegQuality: Double

    public init(
        targetFrameCount: Int = 150,
        maxLongEdge: Int = 1_920,
        jpegQuality: Double = 0.9
    ) {
        self.targetFrameCount = targetFrameCount
        self.maxLongEdge = maxLongEdge
        self.jpegQuality = jpegQuality
    }
}

public struct FrameExtractionResult: Sendable, Equatable {
    public let frameURLs: [URL]
    public let durationSeconds: Double

    public init(frameURLs: [URL], durationSeconds: Double) {
        self.frameURLs = frameURLs
        self.durationSeconds = durationSeconds
    }
}

public struct FrameExtractionProgress: Sendable, Equatable {
    public let completedFrames: Int
    public let totalFrames: Int

    public var fraction: Double {
        Double(completedFrames) / Double(totalFrames)
    }

    public init(completedFrames: Int, totalFrames: Int) {
        self.completedFrames = completedFrames
        self.totalFrames = totalFrames
    }
}

public struct FrameExtractor: Sendable {
    public typealias ProgressHandler = @Sendable (FrameExtractionProgress) async -> Void

    public enum Error: Swift.Error, Equatable {
        case invalidOptions
        case missingVideoTrack
        case outputAlreadyExists(URL)
        case jpegEncodingFailed(URL)
    }

    public init() {}

    public func extract(
        videoURL: URL,
        outputURL: URL,
        options: FrameExtractionOptions = FrameExtractionOptions(),
        progress: ProgressHandler? = nil
    ) async throws -> FrameExtractionResult {
        guard
            options.targetFrameCount > 0,
            options.maxLongEdge > 0,
            options.jpegQuality.isFinite,
            (0...1).contains(options.jpegQuality)
        else {
            throw Error.invalidOptions
        }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw Error.outputAlreadyExists(outputURL)
        }

        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw Error.missingVideoTrack
        }
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let durationSeconds = duration.seconds
        let estimatedFrameCount = nominalFrameRate > 0
            ? max(1, Int((durationSeconds * Double(nominalFrameRate)).rounded(.down)))
            : options.targetFrameCount
        var sampleSeconds = try FrameSamplingPlan.sampleSeconds(
            duration: durationSeconds,
            targetCount: options.targetFrameCount,
            estimatedFrameCount: estimatedFrameCount
        )
        // Sharpness-first: replace each window's midpoint with the crispest
        // frame in that window. Scoring is best-effort — on any decode issue
        // the uniform midpoints above stand.
        do {
            let scored = try await FrameSharpnessScorer.scores(
                asset: asset,
                track: track
            )
            if !scored.isEmpty {
                sampleSeconds = SharpestFrameSelector.times(
                    windowCount: sampleSeconds.count,
                    duration: durationSeconds,
                    scored: scored
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Keep the uniform midpoints.
        }

        let parentURL = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let stagingURL = parentURL.appendingPathComponent(
            ".\(outputURL.lastPathComponent)-\(UUID().uuidString).staging",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: options.maxLongEdge,
            height: options.maxLongEdge
        )
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var names: [String] = []
        names.reserveCapacity(sampleSeconds.count)
        for (index, seconds) in sampleSeconds.enumerated() {
            try Task.checkCancellation()
            let generated = try await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: 60_000)
            )
            let name = String(format: "frame_%04d.jpg", index + 1)
            let frameURL = stagingURL.appendingPathComponent(name)
            try encodeJPEG(
                generated.image,
                to: frameURL,
                quality: options.jpegQuality
            )
            names.append(name)
            await progress?(FrameExtractionProgress(
                completedFrames: index + 1,
                totalFrames: sampleSeconds.count
            ))
        }

        try fileManager.moveItem(at: stagingURL, to: outputURL)
        committed = true
        return FrameExtractionResult(
            frameURLs: names.map { outputURL.appendingPathComponent($0) },
            durationSeconds: durationSeconds
        )
    }

    private func encodeJPEG(
        _ image: CGImage,
        to outputURL: URL,
        quality: Double
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw Error.jpegEncodingFailed(outputURL)
        }
        let properties = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.jpegEncodingFailed(outputURL)
        }
    }
}
