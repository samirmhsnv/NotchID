// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchID",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NotchIDCore", path: "Sources/NotchIDCore"),
        .executableTarget(name: "NotchID", dependencies: ["NotchIDCore"], path: "Sources/NotchID"),
        .testTarget(name: "NotchIDCoreTests", dependencies: ["NotchIDCore"], path: "Tests/NotchIDCoreTests"),
    ]
)
