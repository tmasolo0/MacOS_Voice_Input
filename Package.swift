// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Solo_STT",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Solo_STT",
            dependencies: [
                "SwiftWhisper",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Solo_STT",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "Solo_STTTests",
            dependencies: ["Solo_STT"],
            path: "Tests/Solo_STTTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
