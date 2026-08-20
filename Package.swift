// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpotifyMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic, no AppKit — this is the part the test runner can exercise.
        .target(name: "SpotifyMenuBarCore", path: "Sources/SpotifyMenuBarCore"),
        .executableTarget(
            name: "SpotifyMenuBar",
            dependencies: ["SpotifyMenuBarCore"],
            path: "Sources/SpotifyMenuBar"),
        // An executable, not a .testTarget: the Command Line Tools toolchain ships
        // neither XCTest nor swift-testing, so `swift test` cannot work here.
        .executableTarget(
            name: "SpotifyMenuBarCoreTests",
            dependencies: ["SpotifyMenuBarCore"],
            path: "Sources/SpotifyMenuBarCoreTests"),
    ]
)
