import Foundation

public enum DatasetPathValidator {
    public enum Error: LocalizedError, Equatable {
        case overlappingPaths

        public var errorDescription: String? {
            "Input and output directories must not overlap."
        }
    }

    public static func validateDisjoint(
        inputURL: URL,
        outputURL: URL
    ) throws {
        let input = canonicalURL(inputURL)
        let output = canonicalURL(outputURL)
        guard
            !contains(input, output),
            !contains(output, input)
        else {
            throw Error.overlappingPaths
        }
    }

    private static func canonicalURL(_ url: URL) -> URL {
        let fileManager = FileManager.default
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: existingAncestor.path) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else {
                break
            }
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor = parent
        }
        var resolved = existingAncestor.resolvingSymlinksInPath()
        for component in missingComponents {
            resolved.append(path: component)
        }
        return resolved.standardizedFileURL
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        let parentComponents = parent.pathComponents
        let childComponents = child.pathComponents
        guard childComponents.count >= parentComponents.count else {
            return false
        }
        return zip(parentComponents, childComponents).allSatisfy(==)
    }
}
