import Foundation

public enum ImageDirectoryScanner {
    public static func imageURLs(
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let supportedExtensions = Set(["jpg", "jpeg", "png", "heic"])
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
