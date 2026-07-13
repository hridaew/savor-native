import Foundation
import Metal

enum RuntimeMetalLibrary {
    enum Error: LocalizedError {
        case missingResource(String)

        var errorDescription: String? {
            switch self {
            case let .missingResource(name):
                "Missing packaged Metal shader source: \(name)"
            }
        }
    }

    static func make(device: MTLDevice) throws -> MTLLibrary {
        let source = try [
            source(named: "ShaderCommon", extension: "h"),
            source(named: "SplatProcessing", extension: "h"),
            source(named: "SplatProcessing", extension: "metal"),
            source(named: "SingleStageRenderPath", extension: "metal"),
            source(named: "MultiStageRenderPath", extension: "metal"),
        ]
        .map(removingLocalIncludes)
        .joined(separator: "\n\n")
        return try device.makeLibrary(source: source, options: nil)
    }

    private static func source(
        named name: String,
        extension pathExtension: String
    ) throws -> String {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: pathExtension
        ) else {
            throw Error.missingResource("\(name).\(pathExtension)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func removingLocalIncludes(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let directive = line.trimmingCharacters(in: .whitespaces)
                return directive != "#import \"ShaderCommon.h\""
                    && directive != "#import \"SplatProcessing.h\""
                    && directive != "#include \"SplatProcessing.h\""
            }
            .joined(separator: "\n")
    }
}
