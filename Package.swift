// swift-tools-version: 6.0
//
// RIFFNEX is built without Xcode via xtool (https://github.com/xtool-org/xtool).
// xtool turns the single library product below into the iOS app.
//
// Targets are split so the pure-Swift core (MusicCore) also builds and tests on Linux.
// Set RIFFNEX_CORE_ONLY=1 to drop the Apple-only targets (used by the Linux CI job).
// This must NOT depend on the host OS: xtool evaluates this manifest on Linux/WSL while
// cross-compiling the iOS app.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

var targets: [Target] = [
    .target(
        name: "MusicCore",
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "MusicCoreTests",
        dependencies: ["MusicCore"],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "Persistence",
        dependencies: ["MusicCore"],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "PersistenceTests",
        dependencies: ["Persistence", "MusicCore"],
        swiftSettings: swiftSettings
    ),
]

var products: [Product] = []

let coreOnly = Context.environment["RIFFNEX_CORE_ONLY"] == "1"

if !coreOnly {
    targets += [
        .target(
            name: "DesignSystem",
            dependencies: ["MusicCore"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AnalysisEngine",
            dependencies: ["MusicCore"],
            resources: [
                // Spotify Basic Pitch (Apache-2.0). Copied verbatim; compiled on device at first use
                // because model compilation (coremlc) is only available inside Xcode.
                .copy("Resources/BasicPitch"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AnalysisEngineTests",
            dependencies: ["AnalysisEngine", "MusicCore"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "PlaybackEngine",
            dependencies: ["MusicCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PlaybackEngineTests",
            dependencies: ["PlaybackEngine", "MusicCore"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "RiffnexApp",
            dependencies: ["MusicCore", "DesignSystem", "AnalysisEngine", "Persistence", "PlaybackEngine"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
    // xtool: "An xtool project should contain exactly one library product, representing the main app."
    products = [
        .library(name: "RiffnexApp", targets: ["RiffnexApp"]),
    ]
}

let package = Package(
    name: "Riffnex",
    defaultLocalization: "pt-BR",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
    ],
    products: products,
    targets: targets
)
