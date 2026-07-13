import Foundation

public enum MsplatRuntimeResources {
    public static let version = "1.1.3"
    public static let executableSHA256 =
        "e4ec16d511b610f00def7507a1a67a90471b48a8642fc0e151ea320906cdf211"
    public static let metallibSHA256 =
        "12260298870a122ed3cfc9f539daf5020e0befa1bbaf7b8dfe5b607d8cca78b5"
    public static let coreLibrarySHA256 =
        "74a16ac49fb4e48070dbecf1af0a8bbebe7bbb2007f7ec25265baf7ad1bf8e53"

    public static var directoryURL: URL? {
        Bundle.module.resourceURL?.appendingPathComponent(
            version,
            isDirectory: true
        )
    }
}
