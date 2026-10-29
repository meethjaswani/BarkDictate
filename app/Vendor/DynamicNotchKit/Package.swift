// swift-tools-version: 6.0
// Vendored DynamicNotchKit 1.1.0 (MIT, github.com/MrKai77/DynamicNotchKit), patched to
// build with Command Line Tools only: @Entry → EnvironmentKey, #Preview removed.
import PackageDescription
let package = Package(
    name: "DynamicNotchKit", platforms: [.macOS(.v13)],
    products: [.library(name: "DynamicNotchKit", targets: ["DynamicNotchKit"])],
    targets: [.target(name: "DynamicNotchKit", path: "Sources/DynamicNotchKit")])
