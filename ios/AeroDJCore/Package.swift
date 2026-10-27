// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AeroDJCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AeroDJCore", targets: ["AeroDJCore"]),
    ],
    targets: [
        .target(name: "AeroDJCore"),
        .testTarget(name: "AeroDJCoreTests", dependencies: ["AeroDJCore"]),
    ]
)
