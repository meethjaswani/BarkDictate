// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "BarkDictate", platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "a00964e1aa8eff99c4bce80bc9c8ff2d4dd1568d"),
        .package(path: "Vendor/DynamicNotchKit"),
    ],
    targets: [.executableTarget(name: "BarkDictate",
        dependencies: [
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
        ],
        path: "Sources/BarkDictate",
        swiftSettings: [.swiftLanguageMode(.v5)])])
