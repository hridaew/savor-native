// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MetalSplatter",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "PLYIO", targets: ["PLYIO"]),
        .library(name: "SplatIO", targets: ["SplatIO"]),
        .library(name: "MetalSplatter", targets: ["MetalSplatter"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/scier/spz-swift.git",
            from: "2.1.0"
        ),
    ],
    targets: [
        .target(
            name: "PLYIO",
            path: "PLYIO/Sources"
        ),
        .target(
            name: "SplatIO",
            dependencies: [
                "PLYIO",
                .product(name: "spz", package: "spz-swift"),
            ],
            path: "SplatIO/Sources"
        ),
        .target(
            name: "MetalSplatter",
            dependencies: ["PLYIO", "SplatIO"],
            path: "MetalSplatter",
            sources: ["Sources"],
            resources: [.process("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
