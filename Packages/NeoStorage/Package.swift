// swift-tools-version: 6.0
import PackageDescription

// NeoStorage is a portable persistence package. It must build and test on Linux,
// so it may not depend on SwiftUI, AppKit, UIKit, CoreBluetooth, or any other
// Apple-only framework.
//
// SQLite is reached through a system module rather than a vendored copy. macOS
// ships the header and library in its SDK; a Linux host needs the development
// package (Debian/Ubuntu: `libsqlite3-dev`). `Scripts/test-portable.sh` checks for
// it and prints that hint when it is missing.
let package = Package(
    name: "NeoStorage",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "NeoStorage", targets: ["NeoStorage"])
    ],
    dependencies: [
        .package(path: "../NeoCore")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "NeoStorage",
            dependencies: [
                "CSQLite",
                .product(name: "NeoCore", package: "NeoCore")
            ]
        ),
        .testTarget(
            name: "NeoStorageTests",
            dependencies: ["NeoStorage", .product(name: "NeoCore", package: "NeoCore")]
        )
    ]
)
