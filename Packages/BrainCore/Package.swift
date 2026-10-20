// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BrainCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BrainCore", targets: ["BrainCore"]),
    ],
    targets: [
        .target(name: "BrainCore"),
        .testTarget(name: "BrainCoreTests", dependencies: ["BrainCore"]),
    ]
)
