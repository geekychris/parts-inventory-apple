// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The niimbot tool uses Bluetooth, which needs a usage description: an Info.plist is linked into it.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support/niimbot-Info.plist").path

let package = Package(
    name: "PartsKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PartsKit", targets: ["PartsKit"]),
        .executable(name: "partlookup", targets: ["partlookup"]),
        .executable(name: "niimbot", targets: ["niimbot"]),
    ],
    targets: [
        .target(name: "PartsKit", resources: [.process("Resources")]),
        // Try the supplier APIs from a terminal: `swift run partlookup LM358DR`.
        .executableTarget(name: "partlookup", dependencies: ["PartsKit"]),
        // Find and read NIIMBOT printers from a terminal (it never prints): `swift run niimbot --info`.
        .executableTarget(name: "niimbot", dependencies: ["PartsKit"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]),
        .testTarget(name: "PartsKitTests", dependencies: ["PartsKit"]),
    ]
)
