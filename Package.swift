// swift-tools-version: 6.0
import PackageDescription

// ponytail: SPM + a 15-line bundle script instead of a checked-in .xcodeproj.
// `swift test` on the pure logic is what this needs, and `run.sh` makes the .app.
// Add an xcodeproj the day somebody actually wants ⌘R.
let package = Package(
    name: "Ogi",
    platforms: [.macOS(.v14)],   // NSView.displayLink(target:selector:)
    targets: [
        .target(name: "OgiCore", resources: [.copy("Resources/Sprites")]),
        .executableTarget(name: "Ogi", dependencies: ["OgiCore"]),
        .executableTarget(name: "Decoy"),   // test fixture: a window Ogi can stand on
        .testTarget(name: "OgiCoreTests", dependencies: ["OgiCore"]),
    ]
)
