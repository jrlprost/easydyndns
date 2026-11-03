// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EasyDynDNS",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "EasyDynDNSCore"),
        .executableTarget(name: "EasyDynDNS", dependencies: ["EasyDynDNSCore"]),
        .testTarget(name: "EasyDynDNSCoreTests", dependencies: ["EasyDynDNSCore"]),
    ]
)
