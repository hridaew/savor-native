import Foundation

public enum CaptureState: String, Codable, Sendable {
    case queued
    case extractingFrames
    case estimatingPoses
    case writingDataset
    case training
    case postprocessing
    case completed
    case cancelled
    case interrupted
    case failed

    public var isInFlight: Bool {
        switch self {
        case .queued, .extractingFrames, .estimatingPoses, .writingDataset,
             .training, .postprocessing:
            true
        case .completed, .cancelled, .interrupted, .failed:
            false
        }
    }
}

public struct CaptureCleaningSummary: Codable, Sendable, Equatable {
    public let radius: Float
    public let compactRadius: Float?
    public let totalCount: Int
    public let keptCount: Int
    public let floaterCount: Int
    public let hazeRemovedCount: Int
    public let subjectIsolatedCount: Int?
    public let planeFound: Bool
    public let orbitRadius: Float
    public let isEnvironment: Bool
    public let cameraPosition: [Float]?

    public init(_ result: SplatCleaningResult) {
        radius = result.radius
        compactRadius = result.compactRadius
        totalCount = result.totalCount
        keptCount = result.keptCount
        floaterCount = result.floaterCount
        hazeRemovedCount = result.hazeRemovedCount
        subjectIsolatedCount = result.subjectIsolatedCount
        planeFound = result.planeFound
        orbitRadius = result.orbitRadius
        isEnvironment = result.isEnvironment
        if let position = result.cameraPosition {
            cameraPosition = [position.x, position.y, position.z]
        } else {
            cameraPosition = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        radius = try container.decode(Float.self, forKey: .radius)
        compactRadius = try container.decodeIfPresent(
            Float.self,
            forKey: .compactRadius
        )
        totalCount = try container.decode(Int.self, forKey: .totalCount)
        keptCount = try container.decode(Int.self, forKey: .keptCount)
        floaterCount = try container.decode(Int.self, forKey: .floaterCount)
        hazeRemovedCount = try container.decode(
            Int.self,
            forKey: .hazeRemovedCount
        )
        subjectIsolatedCount = try container.decodeIfPresent(
            Int.self,
            forKey: .subjectIsolatedCount
        )
        planeFound = try container.decode(Bool.self, forKey: .planeFound)
        orbitRadius = try container.decode(Float.self, forKey: .orbitRadius)
        isEnvironment = try container.decode(Bool.self, forKey: .isEnvironment)
        cameraPosition = try container.decodeIfPresent(
            [Float].self,
            forKey: .cameraPosition
        )
    }
}

public struct CaptureRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let sourceFilename: String
    public let sourceRelativePath: String
    public let state: CaptureState
    public let splatRelativePath: String?
    public let rawSplatRelativePath: String?
    public let cleaning: CaptureCleaningSummary?
    public let errorMessage: String?

    public init(
        id: UUID,
        createdAt: Date,
        sourceFilename: String,
        sourceRelativePath: String,
        state: CaptureState,
        splatRelativePath: String? = nil,
        rawSplatRelativePath: String? = nil,
        cleaning: CaptureCleaningSummary? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceFilename = sourceFilename
        self.sourceRelativePath = sourceRelativePath
        self.state = state
        self.splatRelativePath = splatRelativePath
        self.rawSplatRelativePath = rawSplatRelativePath
        self.cleaning = cleaning
        self.errorMessage = errorMessage
    }

    /// Relative splat path for the active viewer mode.
    public func activeSplatRelativePath(unfiltered: Bool) -> String? {
        if unfiltered {
            return rawSplatRelativePath
        }
        return splatRelativePath
    }
}

public actor CaptureRepository {
    public enum Error: Swift.Error, Equatable {
        case captureAlreadyExists(UUID)
        case captureNotFound(UUID)
    }

    public nonisolated let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func createCapture(
        from sourceURL: URL,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> CaptureRecord {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let workspaceURL = workspaceURL(for: id)
        guard !fileManager.fileExists(atPath: workspaceURL.path) else {
            throw Error.captureAlreadyExists(id)
        }

        let stagingURL = rootURL.appendingPathComponent(
            ".\(id.uuidString.lowercased()).staging",
            isDirectory: true
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

        let sourceName = sourceURL.pathExtension.isEmpty
            ? "source"
            : "source.\(sourceURL.pathExtension.lowercased())"
        let copiedSourceURL = stagingURL.appendingPathComponent(sourceName)
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        try fileManager.copyItem(at: sourceURL, to: copiedSourceURL)

        let record = CaptureRecord(
            id: id,
            createdAt: createdAt,
            sourceFilename: sourceURL.lastPathComponent,
            sourceRelativePath: sourceName,
            state: .queued
        )
        try Self.write(record, to: stagingURL)
        try fileManager.moveItem(at: stagingURL, to: workspaceURL)
        committed = true
        return record
    }

    public func loadAll() throws -> [CaptureRecord] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return []
        }
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try directories.compactMap { directory -> CaptureRecord? in
            let metadataURL = directory.appendingPathComponent("capture.json")
            guard fileManager.fileExists(atPath: metadataURL.path) else {
                return nil
            }
            let data = try Data(contentsOf: metadataURL)
            return try Self.decoder.decode(CaptureRecord.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func loadRecoveringInterrupted() throws -> [CaptureRecord] {
        try loadAll().map { record in
            guard record.state.isInFlight else {
                return record
            }
            _ = TrainerProcessRecovery.terminateStaleProcess(
                in: workspaceURL(for: record.id)
                    .appendingPathComponent("training", isDirectory: true)
            )
            let recovered = CaptureRecord(
                id: record.id,
                createdAt: record.createdAt,
                sourceFilename: record.sourceFilename,
                sourceRelativePath: record.sourceRelativePath,
                state: .interrupted,
                splatRelativePath: record.splatRelativePath,
                rawSplatRelativePath: record.rawSplatRelativePath,
                cleaning: record.cleaning,
                errorMessage: "Processing stopped before this capture finished."
            )
            try Self.write(recovered, to: workspaceURL(for: record.id))
            return recovered
        }
    }

    @discardableResult
    public func transition(
        _ id: UUID,
        to state: CaptureState,
        splatRelativePath: String? = nil,
        rawSplatRelativePath: String? = nil,
        cleaning: CaptureCleaningSummary? = nil,
        errorMessage: String? = nil
    ) throws -> CaptureRecord {
        let workspaceURL = workspaceURL(for: id)
        let metadataURL = workspaceURL.appendingPathComponent("capture.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw Error.captureNotFound(id)
        }
        let current = try Self.decoder.decode(
            CaptureRecord.self,
            from: Data(contentsOf: metadataURL)
        )
        let updated = CaptureRecord(
            id: current.id,
            createdAt: current.createdAt,
            sourceFilename: current.sourceFilename,
            sourceRelativePath: current.sourceRelativePath,
            state: state,
            splatRelativePath: splatRelativePath ?? current.splatRelativePath,
            rawSplatRelativePath:
                rawSplatRelativePath ?? current.rawSplatRelativePath,
            cleaning: cleaning ?? current.cleaning,
            errorMessage: errorMessage
        )
        try Self.write(updated, to: workspaceURL)
        return updated
    }

    public func migrateLegacyCompletedCaptures(
        postprocessor: any SplatPostprocessing =
            NativeSplatPostprocessor()
    ) async throws -> [CaptureRecord] {
        let records = try loadAll()
        for record in records {
            guard
                record.state == .completed,
                record.rawSplatRelativePath == nil,
                let currentRelativePath = record.splatRelativePath,
                currentRelativePath != "output/scene-hq.ply"
            else {
                continue
            }
            let workspaceURL = workspaceURL(for: record.id)
            let rawURL = workspaceURL.appendingPathComponent(
                currentRelativePath
            )
            guard FileManager.default.fileExists(atPath: rawURL.path) else {
                continue
            }
            let outputURL = workspaceURL.appendingPathComponent(
                "output/scene-hq.ply"
            )
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            do {
                let result = try await postprocessor.process(
                    inputURL: rawURL,
                    outputURL: outputURL,
                    cameraCenters: Self.loadCameraCenters(
                        from: workspaceURL
                    )
                )
                _ = try transition(
                    record.id,
                    to: .completed,
                    splatRelativePath: "output/scene-hq.ply",
                    rawSplatRelativePath: currentRelativePath,
                    cleaning: CaptureCleaningSummary(result)
                )
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
        }
        return try loadAll()
    }

    public nonisolated func workspaceURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(
            id.uuidString.lowercased(),
            isDirectory: true
        )
    }

    public nonisolated func sourceVideoURL(
        for record: CaptureRecord
    ) -> URL {
        workspaceURL(for: record.id)
            .appendingPathComponent(record.sourceRelativePath)
    }

    private static func loadCameraCenters(
        from workspaceURL: URL
    ) -> [SIMD3<Float>] {
        let transformsURL = workspaceURL.appendingPathComponent(
            "dataset/transforms.json"
        )
        guard
            let data = try? Data(contentsOf: transformsURL),
            let transforms = try? decoder.decode(
                LegacyTransforms.self,
                from: data
            )
        else {
            return []
        }
        return transforms.frames.compactMap { frame in
            let rows = frame.transformMatrix
            guard
                rows.count == 4,
                rows[0].count == 4,
                rows[1].count == 4,
                rows[2].count == 4
            else {
                return nil
            }
            return SIMD3(
                Float(rows[0][3]),
                Float(rows[1][3]),
                Float(rows[2][3])
            )
        }
    }

    private static func write(
        _ record: CaptureRecord,
        to workspaceURL: URL
    ) throws {
        let data = try encoder.encode(record)
        try data.write(
            to: workspaceURL.appendingPathComponent("capture.json"),
            options: .atomic
        )
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct LegacyTransforms: Decodable {
    let frames: [LegacyFrame]
}

private struct LegacyFrame: Decodable {
    let transformMatrix: [[Double]]

    enum CodingKeys: String, CodingKey {
        case transformMatrix = "transform_matrix"
    }
}
