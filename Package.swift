// swift-tools-version:5.6

import PackageDescription

let package = Package(
    name: "CSProgress",
    products: [
        .library(
            name: "CSProgress",
            targets: ["CSProgress"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CSProgress",
            dependencies: []
        ),
        .testTarget(
            name: "CSProgressTests",
            dependencies: ["CSProgress"]
        ),
        .executableTarget(
            name: "CSProgressPerformanceTests",
            dependencies: ["CSProgress"],
            path: "Tests/CSProgressPerformanceTests"
        )
    ]
)
