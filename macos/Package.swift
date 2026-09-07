// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WindowLayouts",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "WindowLayouts",
            path: "Sources/WindowLayouts",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
