// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChessArena",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ChessArena", targets: ["ChessArena"])
    ],
    targets: [
        .target(
            name: "ChessArenaCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("SceneKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("Metal"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "ChessArena",
            dependencies: ["ChessArenaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "ChessArenaCoreTests",
            dependencies: ["ChessArenaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
