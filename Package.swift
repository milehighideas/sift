// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sift",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "SiftCore", path: "Sources/SiftCore"),
        .executableTarget(name: "sift", dependencies: ["SiftCore"], path: "Sources/sift"),
        .testTarget(name: "SiftCoreTests", dependencies: ["SiftCore"], path: "Tests/SiftCoreTests"),
    ]
)
