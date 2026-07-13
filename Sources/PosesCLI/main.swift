import Foundation
import PoseCore
import SplatEngine

@main
struct PosesCLI {
    static func main() async {
        do {
            guard #available(macOS 26.0, *) else {
                throw CLIError.intrinsicsRequireMacOS26
            }
            try await run()
        } catch {
            writeError("poses-cli: \((error as NSError).localizedDescription)\n")
            Foundation.exit(EXIT_FAILURE)
        }
    }

    @available(macOS 26.0, *)
    private static func run() async throws {
        let options: CLIOptions
        do {
            options = try CLIOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            throw CLIError.usage
        }

        let fileManager = FileManager.default
        let inputURL = URL(fileURLWithPath: options.inputPath, isDirectory: true)
            .standardizedFileURL
        let outputURL = URL(fileURLWithPath: options.outputPath, isDirectory: true)
            .standardizedFileURL
        try DatasetPathValidator.validateDisjoint(
            inputURL: inputURL,
            outputURL: outputURL
        )
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw DatasetArtifactWriter.Error.outputAlreadyExists
        }
        let imageURLs = try ImageDirectoryScanner.imageURLs(in: inputURL)

        print("Input: \(imageURLs.count) images")
        print(
            "Configuration: sequential=\(options.useSequentialOrdering), "
                + "highSensitivity=\(options.useHighFeatureSensitivity)"
        )

        let result = try await PoseEstimator().estimate(
            imagesURL: inputURL,
            options: PoseEstimationOptions(
                useSequentialOrdering: options.useSequentialOrdering,
                useHighFeatureSensitivity: options.useHighFeatureSensitivity
            ),
            progress: { progress in
                let percent = Int((progress.fraction * 100).rounded())
                print("\(progress.stage.rawValue): \(percent)%")
            }
        )
        try PoseDatasetWriter.write(
            result,
            imagesURL: inputURL,
            to: outputURL
        )

        print("Wrote \(result.frames.count) registered frames to \(outputURL.path)")
        print("Sparse point cloud: \(result.points.count) points")
        print("Pose sanity checks passed")
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private enum CLIError: LocalizedError {
    case usage
    case intrinsicsRequireMacOS26

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: poses-cli <images-directory> <output-directory> "
                + "[--sequential] [--high-sensitivity]"
        case .intrinsicsRequireMacOS26:
            "Camera intrinsics require macOS 26 or newer."
        }
    }
}
