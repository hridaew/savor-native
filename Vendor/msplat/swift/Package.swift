// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Msplat",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Msplat", targets: ["Msplat"]),
    ],
    targets: [
        .binaryTarget(
            name: "MsplatCore",
            path: "../MsplatCore.xcframework"
        ),
        .target(
            name: "Msplat",
            dependencies: ["MsplatCore"],
            path: "Sources/Msplat",
            resources: [.copy("Resources/default.metallib")],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("Foundation"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
