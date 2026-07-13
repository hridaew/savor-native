import Foundation
import PoseCore
import SplatEngine

@main
enum Phase2Evaluate {
    static func main() async {
        do {
            let arguments = try Arguments.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            let metrics = try await evaluate(arguments)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(metrics)
            try data.write(
                to: arguments.outputURL.appendingPathComponent(
                    "metrics.json"
                ),
                options: .atomic
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(
                Data("phase2-evaluate: \(error.localizedDescription)\n".utf8)
            )
            Foundation.exit(1)
        }
    }

    private static func evaluate(
        _ arguments: Arguments
    ) async throws -> EvaluationMetrics {
        guard !FileManager.default.fileExists(
            atPath: arguments.outputURL.path
        ) else {
            throw EvaluationError.outputAlreadyExists(arguments.outputURL)
        }
        try FileManager.default.createDirectory(
            at: arguments.outputURL,
            withIntermediateDirectories: true
        )

        let backend = try MsplatTrainerFactory.make()
        let training = try await backend.train(
            datasetURL: arguments.datasetURL,
            outputURL: arguments.outputURL.appendingPathComponent(
                "raw",
                isDirectory: true
            ),
            options: TrainingOptions(totalSteps: arguments.steps),
            progress: { progress in
                let percentage = Int(progress.fraction * 100)
                let message = "msplat \(progress.completedSteps)/"
                    + "\(progress.totalSteps) (\(percentage)%)\n"
                FileHandle.standardError.write(
                    Data(message.utf8)
                )
            }
        )
        let cleanedURL = arguments.outputURL.appendingPathComponent(
            "scene-hq.ply"
        )
        let cleaning = try await SplatCleaner.clean(
            inputURL: training.plyURL,
            outputURL: cleanedURL,
            cameraCenters: loadCameraCenters(
                datasetURL: arguments.datasetURL
            )
        )
        let trainerVersion = MsplatExecutableLocator.locate()?.version
            ?? "1.1.3"
        return EvaluationMetrics(
            createdAt: Date(),
            name: arguments.name,
            datasetPath: arguments.datasetURL.path,
            trainerVersion: trainerVersion,
            requestedSteps: arguments.steps,
            sphericalHarmonicsDegree: TrainingOptions().sphericalHarmonicsDegree,
            wallTimeSeconds: training.wallTimeSeconds,
            peakResidentBytes: training.peakResidentBytes,
            rawGaussianCount: training.gaussianCount,
            rawBytes: training.bytes,
            cleanedGaussianCount: cleaning.keptCount,
            cleanedBytes: try fileSize(cleanedURL),
            floaterCount: cleaning.floaterCount,
            hazeRemovedCount: cleaning.hazeRemovedCount,
            subjectIsolatedCount: cleaning.subjectIsolatedCount,
            planeFound: cleaning.planeFound,
            sceneRadius: cleaning.radius,
            orbitRadius: cleaning.orbitRadius,
            isEnvironment: cleaning.isEnvironment,
            reference: try referenceMetrics(arguments.referenceURL)
        )
    }

    private static func referenceMetrics(
        _ url: URL?
    ) throws -> ReferenceMetrics? {
        guard let url else {
            return nil
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4_096) ?? Data()
        return ReferenceMetrics(
            path: url.path,
            gaussianCount: try PLYHeaderReader.vertexCount(in: header),
            bytes: try fileSize(url)
        )
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func loadCameraCenters(
        datasetURL: URL
    ) -> [SIMD3<Float>] {
        let transformsURL = datasetURL.appendingPathComponent(
            "transforms.json"
        )
        guard
            let data = try? Data(contentsOf: transformsURL),
            let transforms = try? JSONDecoder().decode(
                Transforms.self,
                from: data
            )
        else {
            return []
        }
        return transforms.frames.compactMap { frame in
            let matrix = frame.transformMatrix
            guard
                matrix.count == 4,
                matrix[0].count == 4,
                matrix[1].count == 4,
                matrix[2].count == 4
            else {
                return nil
            }
            return SIMD3(
                Float(matrix[0][3]),
                Float(matrix[1][3]),
                Float(matrix[2][3])
            )
        }
    }
}

private struct Arguments {
    let name: String
    let datasetURL: URL
    let referenceURL: URL?
    let outputURL: URL
    let steps: Int

    static func parse(_ arguments: [String]) throws -> Arguments {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw EvaluationError.invalidArguments
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard
            let name = values["--name"],
            let datasetPath = values["--dataset"],
            let outputPath = values["--output"]
        else {
            throw EvaluationError.invalidArguments
        }
        let steps = values["--steps"].flatMap(Int.init) ?? 12_000
        guard steps > 0 else {
            throw EvaluationError.invalidArguments
        }
        let datasetURL = URL(fileURLWithPath: datasetPath)
        guard FileManager.default.fileExists(atPath: datasetURL.path) else {
            throw EvaluationError.missingDataset(datasetURL)
        }
        let referenceURL = values["--reference"].map(
            URL.init(fileURLWithPath:)
        )
        if let referenceURL,
           !FileManager.default.fileExists(atPath: referenceURL.path) {
            throw EvaluationError.missingReference(referenceURL)
        }
        return Arguments(
            name: name,
            datasetURL: datasetURL,
            referenceURL: referenceURL,
            outputURL: URL(fileURLWithPath: outputPath),
            steps: steps
        )
    }
}

private struct EvaluationMetrics: Codable {
    let createdAt: Date
    let name: String
    let datasetPath: String
    let trainerVersion: String
    let requestedSteps: Int
    let sphericalHarmonicsDegree: Int
    let wallTimeSeconds: Double
    let peakResidentBytes: UInt64?
    let rawGaussianCount: Int
    let rawBytes: Int
    let cleanedGaussianCount: Int
    let cleanedBytes: Int
    let floaterCount: Int
    let hazeRemovedCount: Int
    let subjectIsolatedCount: Int
    let planeFound: Bool
    let sceneRadius: Float
    let orbitRadius: Float
    let isEnvironment: Bool
    let reference: ReferenceMetrics?
}

private struct ReferenceMetrics: Codable {
    let path: String
    let gaussianCount: Int
    let bytes: Int
}

private struct Transforms: Decodable {
    let frames: [TransformFrame]
}

private struct TransformFrame: Decodable {
    let transformMatrix: [[Double]]

    enum CodingKeys: String, CodingKey {
        case transformMatrix = "transform_matrix"
    }
}

private enum EvaluationError: LocalizedError {
    case invalidArguments
    case missingRuntime
    case missingDataset(URL)
    case missingReference(URL)
    case outputAlreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: phase2-evaluate --name NAME --dataset PATH "
                + "--output PATH [--reference PLY] [--steps N]"
        case .missingRuntime:
            "The bundled msplat 1.1.3 runtime is unavailable."
        case let .missingDataset(url):
            "Dataset not found at \(url.path)."
        case let .missingReference(url):
            "Reference PLY not found at \(url.path)."
        case let .outputAlreadyExists(url):
            "Evaluation output already exists at \(url.path)."
        }
    }
}
