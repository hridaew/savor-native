public struct CLIOptions {
    public let inputPath: String
    public let outputPath: String
    public let useSequentialOrdering: Bool
    public let useHighFeatureSensitivity: Bool
    public let useObjectMasking: Bool

    public static func parse(arguments: [String]) throws -> CLIOptions {
        guard arguments.count >= 2 else {
            throw Error.invalidArguments
        }
        return CLIOptions(
            inputPath: arguments[0],
            outputPath: arguments[1],
            useSequentialOrdering: arguments.contains("--sequential"),
            useHighFeatureSensitivity: arguments.contains("--high-sensitivity"),
            useObjectMasking: arguments.contains("--object-masking")
        )
    }

    public enum Error: Swift.Error {
        case invalidArguments
    }
}
