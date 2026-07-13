// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SavorNative",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "PoseCore", targets: ["PoseCore"]),
        .library(name: "SplatEngine", targets: ["SplatEngine"]),
        .library(name: "MsplatRuntime", targets: ["MsplatRuntime"]),
        .executable(name: "poses-cli", targets: ["PosesCLI"]),
        .executable(name: "phase2-evaluate", targets: ["Phase2Evaluate"]),
        .executable(name: "phase2-snapshot", targets: ["Phase2Snapshot"]),
        .executable(name: "phase2-reclean", targets: ["Phase2Reclean"]),
        .executable(name: "savor-native", targets: ["SavorNative"]),
        .executable(name: "savor-vision", targets: ["SavorVision"]),
    ],
    dependencies: [
        .package(path: "Vendor/MetalSplatter"),
        .package(name: "Msplat", path: "Vendor/msplat/swift"),
    ],
    targets: [
        .target(name: "PoseCore"),
        .target(
            name: "SplatEngine",
            dependencies: [
                "PoseCore",
                "MsplatRuntime",
                .product(
                    name: "Msplat",
                    package: "Msplat"
                ),
                .product(
                    name: "SplatIO",
                    package: "MetalSplatter"
                ),
            ]
        ),
        .target(
            name: "MsplatRuntime",
            path: "Vendor/msplat",
            exclude: [
                "LICENSE",
                "MsplatCore.xcframework",
                "swift",
            ],
            sources: ["MsplatRuntime.swift"],
            resources: [.copy("1.1.3")]
        ),
        .executableTarget(
            name: "PosesCLI",
            dependencies: ["PoseCore", "SplatEngine"]
        ),
        .executableTarget(
            name: "Phase2Evaluate",
            dependencies: ["PoseCore", "SplatEngine"]
        ),
        .executableTarget(
            name: "Phase2Reclean",
            dependencies: ["SplatEngine"]
        ),
        .executableTarget(
            name: "Phase2Snapshot",
            dependencies: [
                "SplatEngine",
                .product(
                    name: "MetalSplatter",
                    package: "MetalSplatter"
                ),
                .product(
                    name: "SplatIO",
                    package: "MetalSplatter"
                ),
            ]
        ),
        .executableTarget(
            name: "SavorNative",
            dependencies: [
                "SplatEngine",
                .product(
                    name: "MetalSplatter",
                    package: "MetalSplatter"
                ),
                .product(
                    name: "SplatIO",
                    package: "MetalSplatter"
                ),
            ],
            resources: [
                .copy("Resources/Samples"),
                .copy("Resources/AppIcon.icns"),
            ]
        ),
        .executableTarget(
            name: "SavorVision",
            dependencies: [
                "SplatEngine",
                .product(
                    name: "MetalSplatter",
                    package: "MetalSplatter"
                ),
                .product(
                    name: "SplatIO",
                    package: "MetalSplatter"
                ),
            ],
            path: "Sources/SavorVision",
            resources: [
                .copy("Resources/Samples"),
            ]
        ),
        .testTarget(
            name: "PoseCoreTests",
            dependencies: ["PoseCore"]
        ),
        .testTarget(
            name: "SplatEngineTests",
            dependencies: ["SplatEngine"]
        ),
        .testTarget(
            name: "MetalSplatterRuntimeTests",
            dependencies: [
                .product(
                    name: "MetalSplatter",
                    package: "MetalSplatter"
                ),
                .product(
                    name: "SplatIO",
                    package: "MetalSplatter"
                ),
            ]
        ),
    ]
)
