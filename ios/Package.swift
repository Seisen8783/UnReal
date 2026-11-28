// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AConsoleMobile",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AConsoleMobileKit", targets: ["AConsoleMobileKit"]),
    ],
    dependencies: [
        .package(path: "Packages/TrackCore"),
    ],
    targets: [
        .target(
            name: "AConsoleMobileKit",
            dependencies: [
                .product(name: "TrackCore", package: "TrackCore"),
            ],
            path: "AConsoleMobile",
            exclude: [
                "App/MobileApp.swift",
                "Resources/Info.plist",
            ]
        ),
        .testTarget(
            name: "AConsoleMobileTests",
            dependencies: [
                "AConsoleMobileKit",
                .product(name: "TrackCore", package: "TrackCore"),
            ],
            path: "Tests/AConsoleMobileTests"
        ),
    ]
)
