import Foundation
import SplatIO
import simd

@main
struct Main {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            fputs("Usage: RoundTrip INPUT.ply OUTPUT.ply [--sh0] [--clamp-opacity]\n", stderr)
            Foundation.exit(2)
        }
        let input = URL(fileURLWithPath: args[0])
        let output = URL(fileURLWithPath: args[1])
        var points = try await AutodetectSceneReader(input).readAll()
        let clampOpacity = args.contains("--clamp-opacity")
        let sh0Only = args.contains("--sh0")
        var covMax: Float = 0
        var huge = 0
        var samples = 0
        for i in points.indices {
            points[i].rotation = points[i].rotation.normalized
            if clampOpacity {
                let alpha = min(points[i].opacity.asLinearFloat, 0.4)
                points[i].opacity = .linearFloat(alpha)
            }
            if sh0Only {
                points[i].color = .sphericalHarmonicFloat([points[i].color.sh0])
            }

            let scale = points[i].scale.asLinearFloat
            let rotation = points[i].rotation
            let transform = simd_float3x3(rotation) * simd_float3x3(diagonal: scale)
            let cov = transform * transform.transpose
            let magnitude = [
                abs(cov[0, 0]), abs(cov[0, 1]), abs(cov[0, 2]),
                abs(cov[1, 1]), abs(cov[1, 2]), abs(cov[2, 2]),
            ].max() ?? 0
            if i.isMultiple(of: max(1, points.count / 3000)) {
                covMax = max(covMax, magnitude)
                samples += 1
                if magnitude > 1 { huge += 1 }
                if samples <= 3 {
                    print(
                        "sample", i,
                        "scale", scale,
                        "covMax", magnitude,
                        "op", points[i].opacity.asLinearFloat
                    )
                }
            }
        }
        print("covMax", covMax, "hugeApprox", huge, "samples", samples)

        let writer = try SplatPLYSceneWriter(toFileAtPath: output.path)
        try await writer.start(
            sphericalHarmonicDegree: sh0Only ? 0 : 2,
            pointCount: points.count
        )
        try await writer.write(points)
        try await writer.close()
        print("wrote", output.path, "count", points.count)
    }
}
