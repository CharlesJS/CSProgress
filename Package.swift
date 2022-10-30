// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "CSProgress",
    platforms: [
        .macOS(.v10_15),
        .macCatalyst(.v13),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(
            name: "CSProgress",
            targets: ["CSProgress"]
        ),
        .library(
            name: "CSProgress+Foundation",
            targets: ["CSProgress+Foundation"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/CharlesJS/XCTAsyncAssertions", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "CSProgress",
            dependencies: []
        ),
        .target(
            name: "CSProgress+Foundation",
            dependencies: ["CSProgress"]
        ),
        .testTarget(
            name: "CSProgressTests",
            dependencies: ["CSProgress", "CSProgress+Foundation", "XCTAsyncAssertions"]
        ),
        .executableTarget(
            name: "CSProgressPerformanceTests",
            dependencies: ["CSProgress", "CSProgress+Foundation"],
            path: "Tests/CSProgressPerformanceTests",
            swiftSettings: [.unsafeFlags(["-O"])]
        ),
    ]
)
