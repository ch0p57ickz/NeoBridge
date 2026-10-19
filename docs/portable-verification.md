# Portable verification record

This record captures the Linux verification required by
`openspec/changes/initialize-portable-neocore-neoprotocol-packages/tasks.md`
tasks 1.1, 1.2, and 4.2.

## Command

```bash
SWIFT="$HOME/.local/share/swiftly/bin/swift" Scripts/test-portable.sh
```

The script needs a Swift driver on `PATH`, or one named through the `SWIFT`
environment variable.

## Host and toolchain

| Item | Value |
| --- | --- |
| Host platform | Linux (Ubuntu 24.04.5 LTS, aarch64) |
| Toolchain | Swift 6.4.1 (swift-6.4.1-RELEASE), target `aarch64-unknown-linux-gnu` |
| Xcode | Not used |
| Bluetooth hardware | Not used |

## Output

```text
== Toolchain
Swift version 6.4.1 (swift-6.4.1-RELEASE)
Target: aarch64-unknown-linux-gnu
== Forbidden import check
ok: NeoCore imports no Apple-only framework
ok: NeoProtocol imports no Apple-only framework
== Package tests
-- swift test (NeoCore)
     Executed 29 tests, with 0 failures (0 unexpected)
-- swift test (NeoProtocol)
     Executed 62 tests, with 0 failures (0 unexpected)
== Result
PASSED: portable packages build, import no Apple-only framework, and pass their tests.
```

Recorded on 2026-10-19.

## What the script checks

1. Both packages build and pass `swift test` with a Linux toolchain.
2. No source file under `Packages/NeoCore/Sources` or
   `Packages/NeoProtocol/Sources` imports SwiftUI, AppKit, UIKit, WatchKit,
   TVUIKit, CoreBluetooth, CoreGraphics, CoreData, CoreImage, CryptoKit, Combine,
   Metal, MapKit, or XCTest.

## Remaining platform work

- `xcodebuild` and SwiftUI compilation on the macOS runner require an app target,
  which this change does not add (task 4.3).
- Physical A1 acceptance testing requires the pen (tasks 4.1 and 4.3).
