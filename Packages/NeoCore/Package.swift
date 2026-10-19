// swift-tools-version: 6.0
import PackageDescription

// NeoCore is the portable domain package. It must build and test on Linux, so it
// may not depend on SwiftUI, AppKit, UIKit, CoreBluetooth, or any other
// Apple-only framework. SHA-256 comes from swift-crypto, which supports both
// Linux and macOS.
let package = Package(
    name: "NeoCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "NeoCore", targets: ["NeoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.0")
    ],
    targets: [
        .target(
            name: "NeoCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .testTarget(
            name: "NeoCoreTests",
            dependencies: ["NeoCore"]
        )
    ]
)
