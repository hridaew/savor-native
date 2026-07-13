import Foundation
import SplatEngine

@main
enum Phase2Reclean {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count >= 3 else {
                throw RecleanError.usage
            }
            let inputURL = URL(fileURLWithPath: arguments[0])
            let outputURL = URL(fileURLWithPath: arguments[1])
            let datasetURL = URL(fileURLWithPath: arguments[2])
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            let cameraCenters = TransformsCameraCenters.load(
                from: datasetURL.appendingPathComponent("transforms.json")
            )
            let result = try await SplatCleaner.clean(
                inputURL: inputURL,
                outputURL: outputURL,
                cameraCenters: cameraCenters
            )
            let summary = [
                "kept=\(result.keptCount)",
                "floaters=\(result.floaterCount)",
                "haze=\(result.hazeRemovedCount)",
                "isolated=\(result.subjectIsolatedCount)",
                "isEnvironment=\(result.isEnvironment)",
                "orbitRadius=\(result.orbitRadius)",
                "sceneRadius=\(result.radius)",
            ].joined(separator: " ")
            print(summary)
            print(outputURL.path)
        } catch {
            FileHandle.standardError.write(
                Data("phase2-reclean: \(error.localizedDescription)\n".utf8)
            )
            Foundation.exit(1)
        }
    }
}

private enum RecleanError: LocalizedError {
    case usage

    var errorDescription: String? {
        "Usage: phase2-reclean INPUT.ply OUTPUT.ply DATASET_DIR"
    }
}
