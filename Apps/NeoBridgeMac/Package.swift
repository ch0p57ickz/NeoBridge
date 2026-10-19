// swift-tools-version: 6.0
import PackageDescription

// The macOS app package. It links the two portable packages, so it inherits
// their macOS 15.0 deployment floor: `Packages/NeoProtocol` uses
// `Synchronization.Mutex`, which is available only on macOS 15.0 and later.
//
// The protocol and Bluetooth logic lives in `NeoBridgeMacCore` rather than in
// the executable, so a test target can exercise it: a SwiftPM test target cannot
// import an executable target that carries `@main`. The executable stays a thin
// SwiftUI shell.
let package = Package(
    name: "NeoBridgeMac",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "NeoBridgeMacCore", targets: ["NeoBridgeMacCore"]),
        .executable(name: "NeoBridgeMac", targets: ["NeoBridgeMac"])
    ],
    dependencies: [
        .package(path: "../../Packages/NeoCore"),
        .package(path: "../../Packages/NeoExport"),
        .package(path: "../../Packages/NeoProtocol"),
        .package(path: "../../Packages/NeoStorage")
    ],
    targets: [
        .target(
            name: "NeoBridgeMacCore",
            dependencies: [
                .product(name: "NeoCore", package: "NeoCore"),
                .product(name: "NeoExport", package: "NeoExport"),
                .product(name: "NeoProtocol", package: "NeoProtocol"),
                .product(name: "NeoStorage", package: "NeoStorage")
            ]
        ),
        .executableTarget(
            name: "NeoBridgeMac",
            dependencies: [
                "NeoBridgeMacCore",
                .product(name: "NeoCore", package: "NeoCore"),
                .product(name: "NeoProtocol", package: "NeoProtocol")
            ]
        ),
        .testTarget(
            name: "NeoBridgeMacCoreTests",
            dependencies: [
                "NeoBridgeMacCore",
                .product(name: "NeoCore", package: "NeoCore"),
                .product(name: "NeoExport", package: "NeoExport"),
                .product(name: "NeoProtocol", package: "NeoProtocol"),
                .product(name: "NeoStorage", package: "NeoStorage")
            ]
        )
    ]
)
