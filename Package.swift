// swift-tools-version: 6.0
import PackageDescription

// ponytail: SPM + a 15-line bundle script instead of a checked-in .xcodeproj.
// `swift test` on the pure logic is what M0 actually needs. Add the xcodeproj
// when the repo goes public and contributors need ⌘R.
let package = Package(
    name: "Ogi",
    platforms: [.macOS(.v14)],   // NSView.displayLink(target:selector:)
    targets: [
        .target(name: "OgiCore"),
        .executableTarget(name: "Ogi", dependencies: ["OgiCore"]),
        .executableTarget(name: "Decoy"),   // test fixture: a window Ogi can stand on
        .testTarget(name: "OgiCoreTests", dependencies: ["OgiCore"]),
    ]
)
