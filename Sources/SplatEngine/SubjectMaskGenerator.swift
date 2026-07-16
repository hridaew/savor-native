import CoreVideo
import Foundation
import simd
import Vision

/// Generates per-view subject silhouettes for a capture dataset using the
/// Vision framework's foreground-instance segmentation (the same model
/// behind "lift subject" in Photos). Best-effort by design: any failure —
/// missing frames, no salient subject, degenerate masks — returns nil and
/// the cleaner falls back to geometric isolation.
public enum SubjectMaskGenerator {
    /// Long edge of the working mask; silhouette consensus needs shape, not
    /// pixel-perfect edges, and small masks keep 30+ views in ~2 MB.
    private static let maskLongEdge = 320
    /// Dilation passes at mask resolution (~6 px at capture resolution),
    /// protecting subject-edge splats from pose/mask misalignment.
    private static let dilationPasses = 2
    /// Masks covering less (likely a segmentation miss) or more (likely a
    /// whole-scene grab) than these bounds are unusable.
    private static let minimumCoverage: Float = 0.005
    private static let maximumCoverage: Float = 0.7
    private static let minimumUsableViews = 8

    public static func silhouettes(
        datasetURL: URL,
        maximumViews: Int = 30
    ) -> SubjectSilhouettes? {
        guard let transforms = CaptureTransforms.load(
            from: datasetURL.appendingPathComponent("transforms.json")
        ) else {
            return nil
        }
        let frames = transforms.frames
        guard frames.count >= minimumUsableViews else {
            return nil
        }
        let stride = max(1, frames.count / maximumViews)
        var views: [SubjectSilhouettes.View] = []
        for (index, frame) in frames.enumerated()
        where index % stride == 0 {
            let imageURL = datasetURL
                .appendingPathComponent(frame.imagePath)
                .resolvingSymlinksInPath()
            guard let view = silhouetteView(
                frame: frame,
                imageURL: imageURL
            ) else {
                continue
            }
            views.append(view)
        }
        guard views.count >= minimumUsableViews else {
            return nil
        }
        return SubjectSilhouettes(views: views)
    }

    private static func silhouetteView(
        frame: CaptureTransforms.Frame,
        imageURL: URL
    ) -> SubjectSilhouettes.View? {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            return nil
        }
        let handler = VNImageRequestHandler(url: imageURL)
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard
            let observation = request.results?.first,
            !observation.allInstances.isEmpty
        else {
            return nil
        }
        // Capture UX says "keep the object centered", so the instance under
        // the image center IS the subject. Vision's allInstances often
        // bundles the pedestal/stand under it as a second instance — a fat
        // silhouette that lets the environment behind it survive consensus.
        let instances = centeredInstance(of: observation)
            ?? observation.allInstances
        guard let maskBuffer = try? observation.generateScaledMaskForImage(
            forInstances: instances,
            from: handler
        ) else {
            return nil
        }
        guard var bitmap = downsampledBitmap(from: maskBuffer) else {
            return nil
        }
        let coverage = Float(bitmap.mask.lazy.filter { $0 }.count)
            / Float(bitmap.mask.count)
        guard coverage >= minimumCoverage, coverage <= maximumCoverage else {
            return nil
        }
        for _ in 0..<dilationPasses {
            bitmap.mask = dilated(
                bitmap.mask,
                width: bitmap.width,
                height: bitmap.height
            )
        }
        return SubjectSilhouettes.View(
            worldToCamera: frame.worldToCamera,
            focalLengthX: frame.focalLengthX,
            focalLengthY: frame.focalLengthY,
            principalPointX: frame.principalPointX,
            principalPointY: frame.principalPointY,
            imageWidth: Float(frame.width),
            imageHeight: Float(frame.height),
            mask: bitmap.mask,
            maskWidth: bitmap.width,
            maskHeight: bitmap.height
        )
    }

    /// The foreground instance covering the image's central region, probed
    /// at the center and four nearby points (most frequent non-background
    /// label wins). Nil when the center is background — the caller then
    /// keeps every instance rather than guessing.
    private static func centeredInstance(
        of observation: VNInstanceMaskObservation
    ) -> IndexSet? {
        let labels = observation.instanceMask
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(labels, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(labels) else {
            return nil
        }
        let width = CVPixelBufferGetWidth(labels)
        let height = CVPixelBufferGetHeight(labels)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(labels)
        guard width > 0, height > 0 else {
            return nil
        }
        var votes: [UInt8: Int] = [:]
        for (offsetX, offsetY) in [
            (0.5, 0.5), (0.5, 0.4), (0.5, 0.6), (0.42, 0.5), (0.58, 0.5),
        ] {
            let x = min(width - 1, Int(Double(width) * offsetX))
            let y = min(height - 1, Int(Double(height) * offsetY))
            let label = (base + y * bytesPerRow)
                .load(fromByteOffset: x, as: UInt8.self)
            if label != 0 {
                votes[label, default: 0] += 1
            }
        }
        guard let winner = votes.max(by: { $0.value < $1.value })?.key
        else {
            return nil
        }
        return IndexSet(integer: Int(winner))
    }

    /// Max-pools the Vision mask down to the working resolution — block max
    /// is deliberately generous so thin subject parts never vanish in the
    /// downsample.
    private static func downsampledBitmap(
        from buffer: CVPixelBuffer
    ) -> (mask: [Bool], width: Int, height: Int)? {
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        guard sourceWidth > 0, sourceHeight > 0 else {
            return nil
        }
        let scale = Float(maskLongEdge)
            / Float(max(sourceWidth, sourceHeight))
        let width = max(1, min(sourceWidth, Int(Float(sourceWidth) * scale)))
        let height = max(
            1,
            min(sourceHeight, Int(Float(sourceHeight) * scale))
        )

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)

        func sourcePixel(_ x: Int, _ y: Int) -> Bool {
            let row = base + y * bytesPerRow
            switch format {
            case kCVPixelFormatType_OneComponent32Float:
                return row.load(
                    fromByteOffset: x * 4,
                    as: Float32.self
                ) > 0.5
            default:
                return row.load(fromByteOffset: x, as: UInt8.self) > 127
            }
        }

        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let sourceYStart = y * sourceHeight / height
            let sourceYEnd = max(
                sourceYStart + 1,
                (y + 1) * sourceHeight / height
            )
            for x in 0..<width {
                let sourceXStart = x * sourceWidth / width
                let sourceXEnd = max(
                    sourceXStart + 1,
                    (x + 1) * sourceWidth / width
                )
                var hit = false
                outer: for sy in sourceYStart..<sourceYEnd {
                    for sx in sourceXStart..<sourceXEnd
                    where sourcePixel(sx, sy) {
                        hit = true
                        break outer
                    }
                }
                mask[y * width + x] = hit
            }
        }
        return (mask, width, height)
    }

    static func dilated(
        _ mask: [Bool],
        width: Int,
        height: Int
    ) -> [Bool] {
        var result = mask
        for y in 0..<height {
            for x in 0..<width where !mask[y * width + x] {
                let hasNeighbor = (x > 0 && mask[y * width + x - 1])
                    || (x < width - 1 && mask[y * width + x + 1])
                    || (y > 0 && mask[(y - 1) * width + x])
                    || (y < height - 1 && mask[(y + 1) * width + x])
                if hasNeighbor {
                    result[y * width + x] = true
                }
            }
        }
        return result
    }
}
