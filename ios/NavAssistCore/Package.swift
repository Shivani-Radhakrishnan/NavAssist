// swift-tools-version:5.10
import PackageDescription

// Platform-independent navigation logic, kept separate from the iOS app so it
// can be tested on a Mac with `swift test` (no Xcode or iPhone needed).
let package = Package(
    name: "NavAssistCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NavAssistCore", targets: ["NavAssistCore"]),
        // Offline benchmark (macOS): runs the same NavAssistCore code on the TUM RGB-D
        // dataset and on simulated walkers, and writes the CSVs behind the report's figures.
        .executable(name: "navassist-eval", targets: ["NavAssistEval"]),
    ],
    targets: [
        .target(name: "NavAssistCore"),
        .executableTarget(name: "NavAssistEval", dependencies: ["NavAssistCore"]),
        .testTarget(name: "NavAssistCoreTests", dependencies: ["NavAssistCore"]),
    ]
)
