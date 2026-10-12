// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flick",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "FlickCore", targets: ["FlickCore"]),
        .executable(name: "Flick", targets: ["Flick"]),
    ],
    targets: [
        .target(
            name: "FlickCore"
        ),
        .executableTarget(
            name: "Flick",
            dependencies: ["FlickCore"]
        ),
        .testTarget(
            name: "FlickCoreTests",
            dependencies: ["FlickCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
