// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WledCastApp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WledCore", targets: ["WledCore"]),
        .executable(name: "wledcast-swift", targets: ["WledCastApp"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WledCore",
            path: "Sources/WledCore"
        ),
        .executableTarget(
            name: "WledCastApp",
            dependencies: ["WledCore"],
            path: "Sources/WledCastApp"
        ),
        .testTarget(
            name: "WledCoreTests",
            dependencies: ["WledCore"],
            path: "Tests/WledCoreTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
