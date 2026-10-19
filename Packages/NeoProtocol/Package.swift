// swift-tools-version: 6.0
import PackageDescription

// NeoProtocol owns byte framing, packet decoding, version dispatch, and the
// evidence gate. It depends on NeoCore for domain types and must build and test
// on Linux, so it may not import SwiftUI, AppKit, UIKit, or CoreBluetooth.
let package = Package(
    name: "NeoProtocol",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "NeoProtocol", targets: ["NeoProtocol"])
    ],
    dependencies: [
        .package(path: "../NeoCore")
    ],
    targets: [
        .target(
            name: "NeoProtocol",
            dependencies: ["NeoCore"]
        ),
        .testTarget(
            name: "NeoProtocolTests",
            dependencies: ["NeoProtocol", "NeoCore"]
        )
    ]
)
