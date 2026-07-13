import Foundation

public enum MsplatTrainerFactory {
    public enum BackendKind: String, Sendable {
        case inProcess = "in-process"
        case cli = "cli"
    }

    /// Prefer in-process msplat; use CLI when forced via
    /// `SAVOR_MSPLAT_BACKEND=cli` or when the CLI runtime is requested.
    public static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any TrainerBackend {
        let requested = environment["SAVOR_MSPLAT_BACKEND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if requested == BackendKind.cli.rawValue
            || requested == "process" {
            return try makeCLI(environment: environment)
        }
        return MsplatInProcessBackend()
    }

    public static func makeCLI(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> MsplatBackend {
        guard let runtime = MsplatExecutableLocator.locate(
            environment: environment
        ) else {
            throw MsplatBackend.Error.executableMissing(
                URL(fileURLWithPath: "Vendor/msplat/1.1.3/msplat")
            )
        }
        return MsplatBackend(runtime: runtime)
    }
}
