// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fleet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Fleet",
            path: "Sources/Fleet",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
