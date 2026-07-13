import AVFoundation
import CoreVideo
import ImageIO
import XCTest
@testable import SplatEngine

final class FrameExtractorTests: XCTestCase {
    func testExtractsOrientedDownscaledJPEGSequence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let videoURL = root.appendingPathComponent("portrait.mov")
        let outputURL = root.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: videoURL, width: 64, height: 32, frameCount: 4)

        let result = try await FrameExtractor().extract(
            videoURL: videoURL,
            outputURL: outputURL,
            options: FrameExtractionOptions(
                targetFrameCount: 2,
                maxLongEdge: 32,
                jpegQuality: 0.9
            )
        )

        XCTAssertEqual(result.frameURLs.map(\.lastPathComponent), [
            "frame_0001.jpg",
            "frame_0002.jpg",
        ])
        let imageSource = CGImageSourceCreateWithURL(result.frameURLs[0] as CFURL, nil)
        let image = try XCTUnwrap(imageSource.flatMap {
            CGImageSourceCreateImageAtIndex($0, 0, nil)
        })
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 32)
    }

    func testReportsProgressAfterEachWrittenFrame() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let videoURL = root.appendingPathComponent("progress.mov")
        let outputURL = root.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: videoURL, width: 64, height: 32, frameCount: 4)
        let recorder = ProgressRecorder()

        _ = try await FrameExtractor().extract(
            videoURL: videoURL,
            outputURL: outputURL,
            options: FrameExtractionOptions(
                targetFrameCount: 2,
                maxLongEdge: 32,
                jpegQuality: 0.9
            ),
            progress: { progress in
                await recorder.record(progress)
            }
        )

        let values = await recorder.values
        XCTAssertEqual(values.map(\.completedFrames), [1, 2])
        XCTAssertEqual(values.map(\.totalFrames), [2, 2])
    }

    func testCancellationLeavesNoVisibleFrameDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let videoURL = root.appendingPathComponent("cancel.mov")
        let outputURL = root.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: videoURL, width: 64, height: 32, frameCount: 4)
        let (progressStream, continuation) =
            AsyncStream<FrameExtractionProgress>.makeStream()

        let extraction = Task {
            try await FrameExtractor().extract(
                videoURL: videoURL,
                outputURL: outputURL,
                options: FrameExtractionOptions(
                    targetFrameCount: 4,
                    maxLongEdge: 32,
                    jpegQuality: 0.9
                ),
                progress: { progress in
                    continuation.yield(progress)
                    if progress.completedFrames == 1 {
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
            )
        }

        for await progress in progressStream where progress.completedFrames == 1 {
            extraction.cancel()
            continuation.finish()
            break
        }

        do {
            _ = try await extraction.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testRejectsInvalidExtractionOptions() async {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            _ = try await FrameExtractor().extract(
                videoURL: URL(fileURLWithPath: "/unused.mov"),
                outputURL: outputURL,
                options: FrameExtractionOptions(
                    targetFrameCount: 150,
                    maxLongEdge: 0,
                    jpegQuality: 0.9
                )
            )
            XCTFail("Expected invalid options")
        } catch {
            XCTAssertEqual(error as? FrameExtractor.Error, .invalidOptions)
        }
    }

    private func makeVideo(
        at url: URL,
        width: Int,
        height: Int,
        frameCount: Int
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.transform = CGAffineTransform(
            a: 0,
            b: 1,
            c: -1,
            d: 0,
            tx: CGFloat(height),
            ty: 0
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            )
            XCTAssertEqual(status, kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let address = CVPixelBufferGetBaseAddress(buffer) {
                memset(address, Int32(40 + frame * 20), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 4)
            ))
        }

        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}

private actor ProgressRecorder {
    private(set) var values: [FrameExtractionProgress] = []

    func record(_ progress: FrameExtractionProgress) {
        values.append(progress)
    }
}
