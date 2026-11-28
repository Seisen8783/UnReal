// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TrackCore", targets: ["TrackCore"]),
    ],
    targets: [
        .target(
            name: "TrackCore",
            resources: [
                .copy("Resources/default-track.kmz"),
            ]
        ),
        .testTarget(
            name: "TrackCoreTests",
            dependencies: ["TrackCore"]
        ),
    ]
)
