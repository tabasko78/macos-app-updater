// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AppUpdater",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "AppUpdater", path: "Sources/AppUpdater")
    ],
    swiftLanguageModes: [.v5]
)
