// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The niimbot tool uses Bluetooth, which needs a usage description: an Info.plist is linked into it.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support/niimbot-Info.plist").path

// NIIMBOT printing is Bluetooth LE only, and CoreBluetooth only exists on Apple platforms. Everything
// else in PartsKit (and partlookup) is plain Foundation and builds on Linux and Windows too — see
// PORTABILITY.md.
#if canImport(CoreBluetooth)
let hasBluetooth = true
#else
let hasBluetooth = false
#endif

var products: [Product] = [
    .library(name: "PartsKit", targets: ["PartsKit"]),
    .executable(name: "partlookup", targets: ["partlookup"]),
]
var targets: [Target] = [
    // HTTPServer+POSIX.swift's Windows socket path needs Winsock2 (ws2_32); every other platform links nothing extra.
    .target(name: "PartsKit", exclude: hasBluetooth ? [] : ["NiimbotBluetooth.swift"], resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("ws2_32", .when(platforms: [.windows]))]),
    // Try the supplier APIs from a terminal: `swift run partlookup LM358DR`.
    .executableTarget(name: "partlookup", dependencies: ["PartsKit"]),
    .testTarget(name: "PartsKitTests", dependencies: ["PartsKit"], resources: [.copy("Fixtures")]),
]
if hasBluetooth {
    products.append(.executable(name: "niimbot", targets: ["niimbot"]))
    // Find and read NIIMBOT printers from a terminal (it never prints): `swift run niimbot --info`.
    targets.append(.executableTarget(name: "niimbot", dependencies: ["PartsKit"],
                      linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]))
}

let package = Package(
    name: "PartsKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: products,
    targets: targets
)
