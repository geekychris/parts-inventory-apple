// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PartsKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PartsKit", targets: ["PartsKit"])],
    targets: [
        .target(name: "PartsKit", resources: [.process("Resources")]),
        .testTarget(name: "PartsKitTests", dependencies: ["PartsKit"]),
    ]
)
