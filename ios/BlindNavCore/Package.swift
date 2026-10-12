// swift-tools-version:5.10
import PackageDescription

// Platform-independent navigation logic, kept separate from the iOS app so it
// can be tested on a Mac with `swift test` (no Xcode or iPhone needed).
let package = Package(
    name: "BlindNavCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BlindNavCore", targets: ["BlindNavCore"]),
    ],
    targets: [
        .target(name: "BlindNavCore"),
        .testTarget(name: "BlindNavCoreTests", dependencies: ["BlindNavCore"]),
    ]
)
