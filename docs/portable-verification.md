# Portable verification record

This record captures the Linux verification required by
`openspec/changes/initialize-portable-neocore-neoprotocol-packages/tasks.md`
tasks 1.1, 1.2, and 4.2, by
`openspec/changes/correct-a1-codec-from-hardware-evidence/tasks.md` task 3.5, and
by `openspec/changes/add-macos-connect-and-sync/tasks.md` tasks 1.8 and 4.3.

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

## Linux verification for `add-macos-connect-and-sync`

The `add-macos-connect-and-sync` change adds the portable pen session to
NeoProtocol, which takes NeoProtocol from 100 tests to 141. The run below is the
task 1.8 verification on Linux.

| Item | Value |
| --- | --- |
| Host platform | Linux (Ubuntu 26.04.1 LTS, aarch64) in a Docker container on macOS 27.2 (26B5112a), arm64 |
| Container image | `swift:6.4.1` |
| Docker | 28.1.1 (server 28.1.1) |
| Toolchain | Swift 6.4.1 (swift-6.4.1-RELEASE), target `aarch64-unknown-linux-gnu` |
| Xcode | Not used |
| Bluetooth hardware | Not used |
| CPU count in container | 12 |

```bash
docker run -d --name neobridge-swift64 \
  -v "$PWD":/src:ro swift:6.4.1 sleep infinity
docker exec neobridge-swift64 bash -lc \
  'mkdir -p /work && cp -a /src/. /work/ && cd /work && ./Scripts/test-portable.sh'
```

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
     Executed 141 tests, with 0 failures (0 unexpected)
== Result
PASSED: portable packages build with pinned dependencies, import no Apple-only framework, and pass their tests.
```

Recorded on 2026-10-19 (UTC).

`swift test` was also repeated three times on its own and passed 141 tests each
time, so the result is not a single lucky run.

### NeoProtocol suite counts after `add-macos-connect-and-sync`

NeoProtocol, 141 tests:

| Suite | Tests | Added by this change |
| --- | --- | --- |
| `CommandEvidenceTests` | 6 | — |
| `CommandFrameKindTests` | 5 | — |
| `FailedResponseTests` | 4 | — |
| `FixtureReplayTests` | 17 | — |
| `OfflineDiscoveryTests` | 18 | yes |
| `OfflineIntegrationTests` | 13 | — |
| `PenEventDecoderTests` | 14 | — |
| `PenFrameDecoderTests` | 28 | — |
| `PenSessionTests` | 23 | yes |
| `PenVersionInfoTests` | 6 | — |
| `ProtocolVersionTests` | 7 | — |

NeoCore stays at 31 tests.

### Container toolchain defect found during this run

A first attempt ran the same script in a `swift:6.1` container (Swift 6.1.3).
`swift test` there hung nondeterministically: the process stalled inside
`XCTWaiter.wait` → `awaitUsingExpectation` → `RunLoop.run` with only two threads
alive, so the async test closure never got a worker. The hang was not specific to
any test: an empty scratch package holding 30 trivial `async` tests reproduced it,
and it struck purely synchronous suites too. Pinning the process to one CPU
(`taskset -c 0`) made it reliable, and the Swift 6.4.1 container is reliable
without any workaround. Treat the Swift 6.1 Docker image as unusable for these
suites; use the toolchain recorded above.

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

### macOS verification for `add-macos-connect-and-sync`

Task 1.8 also requires the portable suites to pass under the Apple toolchain, and
tasks 2.1 and 4.3 require the app package to build and pass its tests on macOS.
Both ran on the same host:

```bash
SWIFT="/usr/bin/swift" Scripts/test-portable.sh
(cd Apps/NeoBridgeMac && swift test)
```

```text
-- swift test (NeoCore)
     Executed 31 tests, with 0 failures (0 unexpected)
-- swift test (NeoProtocol)
     Executed 141 tests, with 0 failures (0 unexpected)
== Result
PASSED: portable packages build with pinned dependencies, import no Apple-only framework, and pass their tests.
```

`Apps/NeoBridgeMac`, SwiftPM test run:

```text
Test Suite 'NeoBridgeMacCoreTests.xctest' passed
     Executed 54 tests, with 0 failures (0 unexpected)
```

Recorded on 2026-10-19 (PDT). The count is 54 after the physical-A1 acceptance run
added tests for a pen whose first advertisement arrives late, a pen that stays
silent for the whole scan window, a single pen that settles the scan before the
window expires, a cancelled scan, an adapter state that has not resolved yet, the
transport decorator and the traffic transcript, and a link that is released after
a completed read. It was 37 before that run and 32 before the first macOS run.

### Mac app bundle (tasks 4.1, 4.2, and 4.3)

`Scripts/remote-mac-build.sh` is the single macOS entry point. It runs
`Scripts/test-portable.sh`, builds the app with SwiftPM, runs the Xcode gate, and
assembles `Apps/NeoBridgeMac/.build/bundle/NeoBridgeMac.app`. The bundle is
assembled by the script, not by SwiftPM, because CoreBluetooth reads its usage
description from `Info.plist`, which a bare `swift run` executable does not have.

```bash
Scripts/remote-mac-build.sh
```

The Xcode gate runs the app's real scheme from the package's generated Xcode
project, and it succeeded:

```text
== App build (Xcode)
Invocation: xcodebuild -scheme NeoBridgeMac -destination platform=macOS -configuration release -derivedDataPath .../.build/xcode build
Log: .../.build/xcodebuild.log
ok: the Xcode build succeeded.
```

The log shows the app target's own compile and link, not a portable-package build
stand-in:

```text
SwiftDriverJobDiscovery normal arm64 Compiling NeoBridgeMacApp.swift, PenSyncMenu.swift, PenSyncView.swift (in target 'NeoBridgeMac-product' from project 'NeoBridgeMac')
Ld .../release/NeoBridgeMac normal (in target 'NeoBridgeMac-product' from project 'NeoBridgeMac')
** BUILD SUCCEEDED **
```

The compile uses `-target arm64-apple-macos15.0` and SDK `MacOSX27.0` with
`-swift-version 6`.

Bundle verification and result:

```text
== Bundle
assembled Apps/NeoBridgeMac/.build/bundle/NeoBridgeMac.app
== Bundle verification
.../Contents/Info.plist: OK
ok: CFBundleIdentifier = com.sushidev.neobridge.mac
ok: CFBundleExecutable = NeoBridgeMac
ok: LSMinimumSystemVersion = 15.0
ok: NSBluetoothAlwaysUsageDescription = NeoBridge reads offline strokes from a Neo Smartpen A1 over Bluetooth.
ok: LSUIElement = true
.../Contents/MacOS/NeoBridgeMac: Mach-O 64-bit executable arm64
.../NeoBridgeMac.app: valid on disk
.../NeoBridgeMac.app: satisfies its Designated Requirement
== Result
Built .../NeoBridgeMac.app
PASSED: portable packages verified, app built under SwiftPM and Xcode, bundle assembled.
```

Recorded on 2026-10-19 (PDT).

To run the built app:

```bash
open Apps/NeoBridgeMac/.build/bundle/NeoBridgeMac.app
```

`SKIP_XCODE_GATE=1` remains available for a host whose Xcode installation cannot
run `xcodebuild`. A run that uses it prints `INCOMPLETE` and must not be recorded
as satisfying the gate. An earlier attempt on this host needed it: `xcodebuild`
reported Xcode 27.1 failing to load `IDESimulatorFoundation` because
`/Library/Developer/PrivateFrameworks/DVTDownloads.framework` did not match the
installed Xcode. Refreshing the Xcode installation's `PrivateFrameworks` (dated
2026-10-18 23:57 in this run) resolved it, and the gate has passed since.

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

## Physical A1 acceptance (tasks 5.3 and 5.4)

The acceptance run recorded in `Tests/Hardware/README.md` and in the
`## App acceptance run (2026-10-19)` section of `docs/protocol-a1.md` used the
bundle this script assembles. A menu-bar app cannot be driven from a script
without an accessibility grant, so the app binary runs one headless read attempt
when `NEOBRIDGE_ACCEPTANCE_TRACE` names a file:

```bash
NEOBRIDGE_ACCEPTANCE_TRACE=/tmp/a1-run.txt \
  Apps/NeoBridgeMac/.build/bundle/NeoBridgeMac.app/Contents/MacOS/NeoBridgeMac
```

Ten reads completed against a physical A1 (`NWP-F151`, firmware `3.00`, protocol
`2.23`) before the fixes below, and three more after them. Every run's transcript
ends with an `outboundCommands` line listing only `0x01`, `0x21`, `0x22`, `0x23`,
and `0xA4`, so no deletion request was sent.

The run found two defects that no unit test had found:

- The scan window was two seconds, while an independent scan on the same host
  measured the pen's first advertisement after a scan start at 1.0 to 2.5 seconds
  and its longest silent stretch at 3.9 seconds. Roughly half of all reads
  reported "no pen found" with the pen in range. The window is now thirty seconds
  at most, and it settles one second after the first match, so a single pen still
  connects quickly.
- A completed read left the pen connected. A connected peripheral stops
  advertising, so the app's own next read could not find the pen. An attempt now
  releases the link when it ends, whether it succeeded or failed.

A read started immediately after the pen was switched on also reported "no pen
found". A later measurement, with the pen confirmed off and switched on again while a
read was scanning, timed the first advertisement at about three seconds into the scan,
so that delay is variable rather than long. The thirty-second window is sized for the
slower case, and it is spent only when no pen is advertising at all.

One acceptance attempt also reported `Bluetooth is unavailable: the Bluetooth
state is not known yet`, which is real hardware behaviour: CoreBluetooth reports
`.unknown` until it has read the radio. The transport now waits for a resolved
state within a two-second grace window instead of failing the read.

## Remaining platform work

- The portable packages compile and pass under both the Linux and the Apple
  toolchain, the app builds under SwiftPM and Xcode, and the bundle is assembled
  and ad-hoc signed (see above).
- Physical A1 acceptance has been run and recorded (see above). The rows it could
  not reach — a second pen, a Bluetooth toggle, a denied permission prompt, a
  mid-transfer interruption, and the SwiftUI shell — remain unverified in
  `Tests/Hardware/README.md`.

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

Until then, **any target that links NeoProtocol must declare macOS 15.0 or later**.
`Apps/NeoBridgeMac` is the first such target and declares `.macOS(.v15)`; the
assembled bundle carries `LSMinimumSystemVersion = 15.0`. The portable Linux build
is unaffected: `platforms:` is Apple-only metadata.
