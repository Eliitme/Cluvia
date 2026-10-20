// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelmKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HelmKit", targets: ["HelmKit"]),
    ],
    dependencies: [
        .package(path: "../KubeKit"),
    ],
    targets: [
        .target(name: "HelmKit", dependencies: ["KubeKit"]),
        .testTarget(name: "HelmKitTests", dependencies: ["HelmKit"]),
    ]
)
