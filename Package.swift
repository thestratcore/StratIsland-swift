// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StratIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StratIsland",
            path: "Sources/StratIsland",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StratIslandTests",
            dependencies: ["StratIsland"],
            path: "Tests/StratIslandTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
