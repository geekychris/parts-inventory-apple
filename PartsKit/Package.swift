// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PartsKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PartsKit", targets: ["PartsKit"]),
        .executable(name: "partlookup", targets: ["partlookup"]),
    ],
    targets: [
        .target(name: "PartsKit", resources: [.process("Resources")]),
        // Try the supplier APIs from a terminal: `swift run partlookup LM358DR`.
        .executableTarget(name: "partlookup", dependencies: ["PartsKit"]),
        .testTarget(name: "PartsKitTests", dependencies: ["PartsKit"]),
    ]
)
