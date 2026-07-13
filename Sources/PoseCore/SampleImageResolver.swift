import Foundation

public enum SampleImageResolver {
    public enum Error: Swift.Error, Equatable {
        case missingURL(sampleID: Int)
    }

    public static func orderedURLs(
        forSampleIDs sampleIDs: [Int],
        urlsBySample: [Int: URL]
    ) throws -> [URL] {
        try sampleIDs.sorted().map { sampleID in
            guard let url = urlsBySample[sampleID] else {
                throw Error.missingURL(sampleID: sampleID)
            }
            return url
        }
    }
}
