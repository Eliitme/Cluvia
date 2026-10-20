// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KubeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KubeKit", targets: ["KubeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .target(name: "KubeKit", dependencies: ["Yams"]),
        .testTarget(
            name: "KubeKitTests",
            dependencies: ["KubeKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
