// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MTPBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MTPBridgeCore", targets: ["MTPBridgeCore"])
    ],
    targets: [
        .target(
            name: "MTPBridgeCore",
            path: "Sources/MTPBridgeCore"
        ),
        .testTarget(
            name: "MTPBridgeCoreTests",
            dependencies: ["MTPBridgeCore"],
            path: "Tests/MTPBridgeCoreTests"
        )
    ]
)
