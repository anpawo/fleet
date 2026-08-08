// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeFleet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeFleet",
            path: "Sources/ClaudeFleet",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
