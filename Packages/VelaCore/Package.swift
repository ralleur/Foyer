// swift-tools-version: 6.0
import PackageDescription

// VelaCore contains everything that does not need UIKit/AVFoundation:
// Jellyfin API models + client, the playback decision engine, track selection,
// subtitle parsing and supporting utilities. It builds and tests on Linux, which
// keeps the business logic verifiable independent of Xcode.
let package = Package(
    name: "VelaCore",
    platforms: [.tvOS(.v17), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VelaFoundation", targets: ["VelaFoundation"]),
        .library(name: "JellyfinKit", targets: ["JellyfinKit"]),
        .library(name: "PlaybackDecision", targets: ["PlaybackDecision"]),
    ],
    targets: [
        .target(name: "VelaFoundation"),
        .target(name: "JellyfinKit", dependencies: ["VelaFoundation"]),
        .target(name: "PlaybackDecision", dependencies: ["VelaFoundation", "JellyfinKit"]),
        .testTarget(name: "VelaFoundationTests", dependencies: ["VelaFoundation"]),
        .testTarget(
            name: "JellyfinKitTests",
            dependencies: ["JellyfinKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PlaybackDecisionTests", dependencies: ["PlaybackDecision", "JellyfinKit"]),
    ],
    swiftLanguageModes: [.v6]
)
