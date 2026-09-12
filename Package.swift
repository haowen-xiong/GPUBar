// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "GPUBar", platforms: [.macOS(.v15)],
    products: [.executable(name: "GPUBar", targets: ["GPUBar"])],
    targets: [
        .target(name: "GPUBarCore"),
        .executableTarget(name: "GPUBar", dependencies: ["GPUBarCore"]),
        .executableTarget(name: "GPUBarChecks", dependencies: ["GPUBarCore"], path: "Tests/GPUBarCoreTests")
    ]
)
