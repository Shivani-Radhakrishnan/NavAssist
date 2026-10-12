// swift-tools-version:5.10
import PackageDescription

// Platform-independent navigation logic, kept separate from the iOS app so it
// can be tested on a Mac with `swift test` (no Xcode or iPhone needed).
let package = Package(
    name: "NavAssistCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NavAssistCore", targets: ["NavAssistCore"]),
    ],
    targets: [
        .target(name: "NavAssistCore"),
        .testTarget(name: "NavAssistCoreTests", dependencies: ["NavAssistCore"]),
    ]
)
