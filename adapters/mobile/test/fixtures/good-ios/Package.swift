// swift-tools-version:5.9
import PackageDescription

// A tiny dependency-free Swift package so `swift build` is a real, offline
// compile check for the iOS gate path (no network, no external packages).
let package = Package(
    name: "GoodIosApp",
    products: [
        .library(name: "GoodIosApp", targets: ["GoodIosApp"]),
    ],
    targets: [
        .target(name: "GoodIosApp", path: "Sources/GoodIosApp"),
        .testTarget(
            name: "GoodIosAppTests",
            dependencies: ["GoodIosApp"],
            path: "Tests/GoodIosAppTests"
        ),
    ]
)
