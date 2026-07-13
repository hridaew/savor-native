import Foundation

public enum DatasetImageLinker {
    public enum Error: Swift.Error, Equatable {
        case conflictingDestination
    }

    public static func ensureLink(
        from inputURL: URL,
        into outputURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let linkURL = outputURL.appending(
            path: "images",
            directoryHint: .isDirectory
        )
        if fileManager.fileExists(atPath: linkURL.path) {
            guard
                let destination = try? fileManager.destinationOfSymbolicLink(
                    atPath: linkURL.path
                )
            else {
                throw Error.conflictingDestination
            }
            let destinationURL = URL(
                fileURLWithPath: destination,
                relativeTo: linkURL.deletingLastPathComponent()
            ).standardizedFileURL
            guard destinationURL == inputURL.standardizedFileURL else {
                throw Error.conflictingDestination
            }
            return
        }
        try fileManager.createSymbolicLink(
            at: linkURL,
            withDestinationURL: inputURL
        )
    }
}
