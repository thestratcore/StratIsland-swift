// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchIsland",
            path: "Sources/NotchIsland",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
