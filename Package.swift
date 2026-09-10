// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDuo",
    platforms: [.macOS(.v14)],
    targets: [
        // The effect itself: sensor, capture, Metal pipeline, overlay window.
        // Its own library target so the runtime probe can exercise the exact
        // code the app runs.
        .target(
            name: "MacDuoCore",
            path: "Sources/MacDuoCore",
            // The shader is compiled to default.metallib by build.sh/verify.sh.
            exclude: ["Render/MetalFrost.metal"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Menu bar UI shell.
        .executableTarget(
            name: "MacDuo",
            dependencies: ["MacDuoCore"],
            path: "Sources/MacDuo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Offscreen verification harness (see verify.sh).
        .executableTarget(
            name: "MacDuoProbe",
            dependencies: ["MacDuoCore"],
            path: "Tools/MacDuoProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
