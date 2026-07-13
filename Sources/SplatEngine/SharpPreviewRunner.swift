import Foundation

/// Locator + CLI wrapper for Apple's optional SHARP instant preview.
public enum SharpPreviewRunner {
    public enum Error: LocalizedError, Equatable {
        case binaryMissing
        case processFailed(Int32, String)
        case missingOutput(URL)

        public var errorDescription: String? {
            switch self {
            case .binaryMissing:
                "SHARP is not installed. Run scripts/setup-sharp.sh."
            case let .processFailed(status, output):
                "sharp exited with status \(status): \(output)"
            case let .missingOutput(url):
                "SHARP did not produce a PLY at \(url.path)."
            }
        }
    }

    public static func resolveBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        if let override = environment["SAVOR_SHARP_BIN"] {
            let url = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        let defaultURL = homeDirectory
            .appendingPathComponent(".savor-native/sharp/bin/sharp")
        if fileManager.isExecutableFile(atPath: defaultURL.path) {
            return defaultURL
        }
        return nil
    }

    public static func makeArguments(
        inputImageURL: URL,
        outputDirectoryURL: URL
    ) -> [String] {
        [
            "predict",
            "-i", inputImageURL.path,
            "-o", outputDirectoryURL.path,
        ]
    }

    /// Runs SHARP if installed. Returns nil when the binary is missing
    /// so callers can treat preview as optional.
    public static func runIfAvailable(
        inputImageURL: URL,
        outputPLYURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) async throws -> URL? {
        guard let binary = resolveBinary(environment: environment) else {
            return nil
        }
        return try await run(
            binaryURL: binary,
            inputImageURL: inputImageURL,
            outputPLYURL: outputPLYURL,
            fileManager: fileManager
        )
    }

    public static func run(
        binaryURL: URL,
        inputImageURL: URL,
        outputPLYURL: URL,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let staging = outputPLYURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "sharp-staging-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = makeArguments(
            inputImageURL: inputImageURL,
            outputDirectoryURL: staging
        )
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile()
                + stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            throw Error.processFailed(process.terminationStatus, diagnostic)
        }

        let produced = try locatePLY(in: staging, fileManager: fileManager)
        let parent = outputPLYURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: outputPLYURL.path) {
            try fileManager.removeItem(at: outputPLYURL)
        }
        try fileManager.copyItem(at: produced, to: outputPLYURL)
        return outputPLYURL
    }

    private static func locatePLY(
        in directory: URL,
        fileManager: FileManager
    ) throws -> URL {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if let ply = urls.first(where: {
            $0.pathExtension.lowercased() == "ply"
        }) {
            return ply
        }
        for url in urls where url.hasDirectoryPath {
            if let nested = try? locatePLY(in: url, fileManager: fileManager) {
                return nested
            }
        }
        throw Error.missingOutput(directory)
    }
}
