// swift-tools-version: 6.0
//
// RIFFNEX is built without Xcode via xtool (https://github.com/xtool-org/xtool).
// xtool turns the single library product below into the iOS app.
//
// Targets are split so the pure-Swift core (MusicCore) also builds and tests on Linux.
// Apple-only targets are excluded from the manifest on non-Apple hosts.

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
]

var products: [Product] = []

#if !os(Linux) && !os(Windows)
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
    .target(
        name: "RiffnexApp",
        dependencies: ["MusicCore", "DesignSystem", "AnalysisEngine"],
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
#endif

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
