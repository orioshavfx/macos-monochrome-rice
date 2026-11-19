// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "rice-settings",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "rice-settings", path: "Sources/rice-settings")
    ]
)
