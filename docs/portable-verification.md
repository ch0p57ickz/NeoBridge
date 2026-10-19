# Portable verification record

This record captures the Linux verification required by
`openspec/changes/initialize-portable-neocore-neoprotocol-packages/tasks.md`
tasks 1.1, 1.2, and 4.2, and by
`openspec/changes/correct-a1-codec-from-hardware-evidence/tasks.md` task 3.5.

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
== Pinned dependency resolution
-- swift build --disable-automatic-resolution (NeoCore)
-- swift build --disable-automatic-resolution (NeoProtocol)
== Package tests
-- swift test (NeoCore)
     Executed 31 tests, with 0 failures (0 unexpected)
-- swift test (NeoProtocol)
     Executed 100 tests, with 0 failures (0 unexpected)
== Result
PASSED: portable packages build with pinned dependencies, import no Apple-only framework, and pass their tests.
```

Recorded on 2026-10-19 (UTC), 2026-10-18 (PDT).

### Suite counts

NeoCore, 31 tests:

| Suite | Tests |
| --- | --- |
| `PageIdentityTests` | 4 |
| `PenDomainInterfaceTests` | 7 |
| `StrokeAssemblerTests` | 10 |
| `StrokeIdentityTests` | 10 |

NeoProtocol, 100 tests:

| Suite | Tests |
| --- | --- |
| `CommandEvidenceTests` | 6 |
| `CommandFrameKindTests` | 5 |
| `FailedResponseTests` | 4 |
| `FixtureReplayTests` | 17 |
| `OfflineIntegrationTests` | 13 |
| `PenEventDecoderTests` | 14 |
| `PenFrameDecoderTests` | 28 |
| `PenVersionInfoTests` | 6 |
| `ProtocolVersionTests` | 7 |

The codec change `correct-a1-codec-from-hardware-evidence` took NeoProtocol from
67 tests to 100, covering response framing, the failed-response path, the version
payload layout, and the capture-derived handshake fixture.

## macOS verification (Apple toolchain)

The portable packages also build and pass their tests with the Apple toolchain on
a local macOS host. This is the "compile on a Mac" half of the design's
Linux/Mac compiler-differences risk; the remote mac runner and physical A1 steps
stay with task 4.3.

```bash
SWIFT="$(xcrun -f swift)" Scripts/test-portable.sh
```

| Item | Value |
| --- | --- |
| Host platform | macOS 27.2 (26B5112a), arm64 |
| Toolchain | Apple Swift 6.4 (swiftlang-6.4.0.34.1), target `arm64-apple-macosx27.2.0` |
| Xcode | 27.1 (27A9275), SDK `MacOSX27.0` |

```text
== Toolchain
swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
Target: arm64-apple-macosx27.2.0
== Forbidden import check
ok: NeoCore imports no Apple-only framework
ok: NeoProtocol imports no Apple-only framework
== Pinned dependency resolution
-- swift build --disable-automatic-resolution (NeoCore)
-- swift build --disable-automatic-resolution (NeoProtocol)
== Package tests
-- swift test (NeoCore)
     Executed 31 tests, with 0 failures (0 unexpected)
-- swift test (NeoProtocol)
     Executed 100 tests, with 0 failures (0 unexpected)
== Result
PASSED: portable packages build with pinned dependencies, import no Apple-only framework, and pass their tests.
```

Recorded on 2026-10-18 (PDT).

### macOS-only compile failure fixed

The first Apple-toolchain build failed with
`'Mutex' is only available in macOS 15.0 or newer`. `FakePenTransport` guards its
state with `Synchronization.Mutex`, whose `Mutex` type, initializer, and
`withLock` are available only on macOS 15.0 and later, while
`Packages/NeoProtocol/Package.swift` declared `.macOS(.v13)`. Linux applies no
such availability gate, so the mismatch surfaced only on macOS — exactly the
Linux/Mac compiler difference the design called out.

Raising NeoProtocol's deployment target to `.macOS(.v15)` fixes the build. The
declaration is Apple-only platform metadata, so the Linux build and tests are
unaffected. NeoCore stays at `.macOS(.v13)` because it does not use
`Synchronization` and swift-crypto declares no macOS floor.

## Fixture sanitization

Verified when the capture-derived handshake fixture landed:

- `Tests/Fixtures/raw/` is git-ignored (`.gitignore` line 64) and no raw capture
  is tracked, so the unsanitized log stays out of the repository.
- The handshake fixture zeroes the version response's Bluetooth address field.
  `FixtureReplayTests.testNoFixtureCarriesADeviceAddressInAVersionPayload` reads
  that field's content for every version response, both as each fixture declares it
  and as its wire bytes decode, so it holds independently of the sanitization
  metadata.
- The advertised device address, the device serial, and any password material are
  absent from the fixture files, and no fixture carries stroke content from the
  pen. The request's connection code is the SDK default of sixteen zero bytes.

## What the script checks

1. Both packages build and pass `swift test` with a Linux toolchain.
2. No source file under `Packages/NeoCore/Sources` or
   `Packages/NeoProtocol/Sources` imports SwiftUI, AppKit, UIKit, WatchKit,
   TVUIKit, CoreBluetooth, CoreGraphics, CoreData, CoreImage, CryptoKit, Combine,
   Metal, MapKit, or XCTest.
3. `swift build --disable-automatic-resolution` succeeds for both packages, so
   the committed `Package.resolved` files are complete and the build performs no
   further dependency resolution.

## Network use

The test suites make no network calls. The only network step is the first fetch
of the pinned `swift-crypto` and `swift-asn1` revisions into the SwiftPM
dependency cache. Check 3 above constrains resolution, not fetching: it proves
the build does not re-resolve, so a warm dependency cache needs no network. A
cold machine needs one fetch.

## Remaining platform work

- The portable packages compile and pass under the Apple toolchain (see above).
- An `xcodebuild` and SwiftUI compile of the app target still requires the app
  target, which no change adds yet (task 4.3).
- Physical A1 acceptance testing requires the pen (tasks 4.1 and 4.3).

## macOS deployment floor

The macOS 15.0 floor described above applies to any target that links
`Packages/NeoProtocol`, even though the requirement originates in the
`FakePenTransport` test double. Two consequences are worth keeping in view:

- The floor is package-level, so a separate target cannot carry the fake while
  NeoProtocol keeps a lower minimum.
- The fake is public API, and the repository references it only from
  `NeoProtocolTests`. If macOS 13 or 14 support ever becomes a product requirement,
  the floor comes down by moving the fake's synchronization off the macOS 15-only
  API (for example, making it an `actor`), not by lowering the deployment target.

Until then, **any target that links NeoProtocol must declare macOS 15.0 or later**,
so a future `Apps/NeoBridgeMac` should use the same floor. The portable Linux build
is unaffected: `platforms:` is Apple-only metadata.
