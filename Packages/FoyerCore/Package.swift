// swift-tools-version: 6.0
import PackageDescription

// FoyerCore contains everything that does not need UIKit/AVFoundation:
// Jellyfin API models + client, the playback decision engine, track selection,
// subtitle parsing and supporting utilities. It builds and tests on Linux, which
// keeps the business logic verifiable independent of Xcode.
let package = Package(
    name: "FoyerCore",
    platforms: [.tvOS(.v17), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FoyerFoundation", targets: ["FoyerFoundation"]),
        .library(name: "JellyfinKit", targets: ["JellyfinKit"]),
        .library(name: "PlaybackDecision", targets: ["PlaybackDecision"]),
    ],
    targets: [
        .target(name: "FoyerFoundation"),
        .target(name: "JellyfinKit", dependencies: ["FoyerFoundation"]),
        .target(name: "PlaybackDecision", dependencies: ["FoyerFoundation", "JellyfinKit"]),
        .testTarget(name: "FoyerFoundationTests", dependencies: ["FoyerFoundation"]),
        .testTarget(
            name: "JellyfinKitTests",
            dependencies: ["JellyfinKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PlaybackDecisionTests", dependencies: ["PlaybackDecision", "JellyfinKit"]),
    ],
    swiftLanguageModes: [.v6]
)
