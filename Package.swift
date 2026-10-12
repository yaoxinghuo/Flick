// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Peek",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "PeekCore", targets: ["PeekCore"]),
        .executable(name: "Peek", targets: ["Peek"]),
    ],
    targets: [
        .target(
            name: "PeekCore"
        ),
        .executableTarget(
            name: "Peek",
            dependencies: ["PeekCore"]
        ),
        .testTarget(
            name: "PeekCoreTests",
            dependencies: ["PeekCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
