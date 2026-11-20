// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wallpicker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "wallpicker", path: "Sources/wallpicker")
    ]
)
