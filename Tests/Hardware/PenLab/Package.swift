// swift-tools-version: 6.0
import PackageDescription

// The physical-A1 experiment tool.
//
// It lives outside the app package on purpose. The app cannot send `0x25` or
// `0x27`: `PenCommand.frameKind` returns `nil` for both, so `PenFrameEncoder`
// refuses to build them and the evidence registry reports them as gated. The only
// way to establish their wire behaviour is to send them deliberately, so that code
// belongs in a tool that no app target can reach.
//
// CoreBluetooth has no Linux counterpart, so this package is macOS-only and is not
// in `Scripts/test-portable.sh`'s package list. `Scripts/pen-lab-build.sh` builds it
// and assembles the bundle it needs for its Bluetooth usage description.
let package = Package(
    name: "PenLab",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(path: "../../../Apps/NeoBridgeMac"),
        .package(path: "../../../Packages/NeoCore"),
        .package(path: "../../../Packages/NeoProtocol")
    ],
    targets: [
        .executableTarget(
            name: "PenLab",
            dependencies: [
                .product(name: "NeoBridgeMacCore", package: "NeoBridgeMac"),
                .product(name: "NeoCore", package: "NeoCore"),
                .product(name: "NeoProtocol", package: "NeoProtocol")
            ]
        ),
        // An executable target carries `@main`, which a test target cannot import,
        // so the framing the experiment sends lives in `PenLabFrames` and the tests
        // reach it through the module rather than through the command line.
        .testTarget(
            name: "PenLabTests",
            dependencies: [
                "PenLab",
                .product(name: "NeoProtocol", package: "NeoProtocol")
            ]
        )
    ]
)
