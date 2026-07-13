import Foundation

public enum DatasetArtifactWriter {
    public enum Error: LocalizedError, Equatable {
        case outputAlreadyExists

        public var errorDescription: String? {
            "Output directory already exists; choose a new directory."
        }
    }

    public static func write(
        frames: [DatasetFrame],
        totalImageCount: Int,
        points: [PointCloudPoint],
        to outputURL: URL
    ) throws {
        try write(
            frames: frames,
            totalImageCount: totalImageCount,
            points: points,
            imagesURL: nil,
            to: outputURL,
            fileManager: .default,
            dataWriter: { data, url in
                try data.write(to: url, options: .atomic)
            }
        )
    }

    public static func write(
        frames: [DatasetFrame],
        totalImageCount: Int,
        points: [PointCloudPoint],
        imagesURL: URL,
        to outputURL: URL
    ) throws {
        try write(
            frames: frames,
            totalImageCount: totalImageCount,
            points: points,
            imagesURL: imagesURL,
            to: outputURL,
            fileManager: .default,
            dataWriter: { data, url in
                try data.write(to: url, options: .atomic)
            }
        )
    }

    static func write(
        frames: [DatasetFrame],
        totalImageCount: Int,
        points: [PointCloudPoint],
        imagesURL: URL,
        to outputURL: URL,
        fileManager: FileManager,
        dataWriter: (Data, URL) throws -> Void
    ) throws {
        try write(
            frames: frames,
            totalImageCount: totalImageCount,
            points: points,
            imagesURL: Optional(imagesURL),
            to: outputURL,
            fileManager: fileManager,
            dataWriter: dataWriter
        )
    }

    private static func write(
        frames: [DatasetFrame],
        totalImageCount: Int,
        points: [PointCloudPoint],
        imagesURL: URL?,
        to outputURL: URL,
        fileManager: FileManager,
        dataWriter: (Data, URL) throws -> Void
    ) throws {
        try PoseSanity.validate(
            frames: frames.map {
                PoseFrame(
                    imageName: $0.imagePath,
                    cameraToWorld: $0.cameraToWorld
                )
            },
            totalImageCount: totalImageCount,
            points: points.map(\.position)
        )

        if let imagesURL {
            try DatasetPathValidator.validateDisjoint(
                inputURL: imagesURL,
                outputURL: outputURL
            )
        }
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw Error.outputAlreadyExists
        }

        let transformsData = try NerfstudioDatasetEncoder.encode(
            frames: frames,
            pointCloudPath: "sparse_pc.ply"
        )
        let pointCloudData = PointCloudPLYEncoder.encode(points: points)

        let parentURL = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        let stagingURL = parentURL.appending(
            path: ".\(outputURL.lastPathComponent).staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false
        )
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        if let imagesURL {
            try DatasetImageLinker.ensureLink(
                from: imagesURL,
                into: stagingURL,
                fileManager: fileManager
            )
        }
        try dataWriter(
            transformsData,
            stagingURL.appending(path: "transforms.json")
        )
        try dataWriter(
            pointCloudData,
            stagingURL.appending(path: "sparse_pc.ply")
        )
        try fileManager.moveItem(at: stagingURL, to: outputURL)
        committed = true
    }
}
