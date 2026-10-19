// swift-tools-version: 6.0
import PackageDescription

// Integrated verification. The scenarios drive a whole offline read through the
// portable session, storage, and export packages over a fake transport, so they
// run on Linux and may not import any Apple-only framework.
let package = Package(
    name: "NeoBridgeIntegration",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "NeoBridgeIntegration", targets: ["NeoBridgeIntegration"])
    ],
    dependencies: [
        .package(path: "../../Packages/NeoCore"),
        .package(path: "../../Packages/NeoExport"),
        .package(path: "../../Packages/NeoProtocol"),
        .package(path: "../../Packages/NeoStorage")
    ],
    targets: [
        .target(
            name: "NeoBridgeIntegration",
            dependencies: [
                .product(name: "NeoCore", package: "NeoCore"),
                .product(name: "NeoExport", package: "NeoExport"),
                .product(name: "NeoProtocol", package: "NeoProtocol"),
                .product(name: "NeoStorage", package: "NeoStorage")
            ]
        ),
        .testTarget(
            name: "NeoBridgeIntegrationTests",
            dependencies: [
                "NeoBridgeIntegration",
                .product(name: "NeoCore", package: "NeoCore"),
                .product(name: "NeoExport", package: "NeoExport"),
                .product(name: "NeoProtocol", package: "NeoProtocol"),
                .product(name: "NeoStorage", package: "NeoStorage")
            ]
        )
    ]
)
