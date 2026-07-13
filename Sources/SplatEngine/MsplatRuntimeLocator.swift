import Foundation
import MsplatRuntime

public struct MsplatRuntimeLocation: Sendable, Equatable {
    public let executableURL: URL
    public let metallibURL: URL
    public let version: String

    public init(
        executableURL: URL,
        metallibURL: URL,
        version: String
    ) {
        self.executableURL = executableURL
        self.metallibURL = metallibURL
        self.version = version
    }
}

public enum MsplatExecutableLocator {
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MsplatRuntimeLocation? {
        if let override = environment["SAVOR_MSPLAT_DIR"],
           let location = validate(
               directoryURL: URL(fileURLWithPath: override)
           ) {
            return location
        }
        if let directoryURL = MsplatRuntimeResources.directoryURL,
           let location = validate(directoryURL: directoryURL) {
            return MsplatRuntimeLocation(
                executableURL: location.executableURL,
                metallibURL: location.metallibURL,
                version: MsplatRuntimeResources.version
            )
        }
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return validate(directoryURL: sourceRoot
            .appendingPathComponent("Vendor/msplat/1.1.3"))
    }

    public static func validate(
        directoryURL: URL
    ) -> MsplatRuntimeLocation? {
        let executableURL = directoryURL.appendingPathComponent("msplat")
        let metallibURL = directoryURL.appendingPathComponent(
            "default.metallib"
        )
        guard
            FileManager.default.isExecutableFile(
                atPath: executableURL.path
            ),
            FileManager.default.fileExists(atPath: metallibURL.path)
        else {
            return nil
        }
        return MsplatRuntimeLocation(
            executableURL: executableURL,
            metallibURL: metallibURL,
            version: directoryURL.lastPathComponent
        )
    }
}

public enum MsplatArguments {
    public static func make(
        datasetURL: URL,
        outputPLYURL: URL,
        options: TrainingOptions
    ) -> [String] {
        var arguments = [
            datasetURL.path,
            "-o", outputPLYURL.path,
            "-n", String(options.totalSteps),
            "--save-every", String(options.exportInterval),
            "--sh-degree", String(options.sphericalHarmonicsDegree),
            "--refine-every", String(options.refineEvery),
            "--warmup-length", String(options.warmupLength),
            "--reset-alpha-every", String(options.resetAlphaEvery),
            "--densify-grad-thresh", formatFloat(options.densifyGradThresh),
            "--densify-size-thresh", formatFloat(options.densifySizeThresh),
            "--stop-screen-size-at", String(options.stopScreenSizeAt),
            "--split-screen-size", formatFloat(options.splitScreenSize),
        ]
        if options.keepCoordinateSystem {
            arguments.append("--keep-crs")
        }
        return arguments
    }

    private static func formatFloat(_ value: Float) -> String {
        String(format: "%g", value)
    }
}

public enum MsplatProgressParser {
    private static let patterns = [
        #"(?:step|iter(?:ation)?)\s*[=:]\s*(\d+)"#,
        #"\[\s*(\d+)\s*/\s*\d+\s*\]"#,
    ]

    public static func step(in line: String) -> Int? {
        let range = NSRange(line.startIndex..., in: line)
        for pattern in patterns {
            guard
                let expression = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                ),
                let match = expression.firstMatch(
                    in: line,
                    range: range
                ),
                let valueRange = Range(match.range(at: 1), in: line)
            else {
                continue
            }
            return Int(line[valueRange])
        }
        return nil
    }
}
