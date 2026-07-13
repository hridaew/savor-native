// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RoundTrip",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "/Users/hridaewalia/Savor-New/Vendor/MetalSplatter"),
    ],
    targets: [
        .executableTarget(
            name: "RoundTrip",
            dependencies: [
                .product(name: "SplatIO", package: "MetalSplatter"),
            ]
        )
    ]
)
