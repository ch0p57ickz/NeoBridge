// swift-tools-version: 6.0
import PackageDescription

// NeoExport is a portable export package. It must build and test on Linux, so it
// may not depend on AppKit, CoreGraphics, SwiftUI, or any other Apple-only
// framework. It writes bytes and files; the app owns the security-scoped access
// to a user-selected directory.
let package = Package(
    name: "NeoExport",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "NeoExport", targets: ["NeoExport"])
    ],
    dependencies: [
        .package(path: "../NeoCore")
    ],
    targets: [
        .target(
            name: "NeoExport",
            dependencies: [.product(name: "NeoCore", package: "NeoCore")]
        ),
        .testTarget(
            name: "NeoExportTests",
            dependencies: ["NeoExport", .product(name: "NeoCore", package: "NeoCore")]
        )
    ]
)
