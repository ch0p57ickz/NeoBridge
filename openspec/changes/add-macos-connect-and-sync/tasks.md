# Tasks

## 1. Portable pen session (NeoProtocol)

- [ ] 1.1 Add a portable session type in `Packages/NeoProtocol` that consumes `PenTransport` and exposes the `pen-session` lifecycle states and the assembled result; verify a Linux `swift test` drives a session over `FakePenTransport` through idle, connecting, verifying, syncing, and complete in that order, and a rejected default `0x01` connection code fails without trying another code
- [ ] 1.2 Gate offline retrieval on the validated-minor policy; verify a test that a validated minor proceeds to `0x21` discovery and a test that an unvalidated minor reports unsupported and sends no offline request
- [ ] 1.3 Establish the initial `sectionOwnerId` or documented wildcard needed by `0x21` from official SDK or sanitized A1 evidence; add evidence-backed decoding for `0xA1` note and `0xA2` page lists, with sanitized fixtures; implement `0x21` then `0x22` discovery and form each `0x23` request from discovered identifiers using the traced transfer options and zero page count; verify tests for a discovered note, empty list, malformed list, multiple notes, and missing bootstrap evidence (which must send no list request)
- [ ] 1.4 Implement the `0x23` request, `0xA3` read, `0x24` assembly, and `0xA4` acknowledgement (Continue until the end packet, Stop for it); verify a send-responsive transport releases one packet per acknowledgement, checks matching packet IDs and operations, completes a three-packet transfer, fails on nonzero response errors and packet gaps, and reports a stream ending before the end packet as incomplete even if it finishes normally
- [ ] 1.5 Keep deletion disabled; verify a test that a completed fake sync sends no `0x25` or `0x27` command
- [ ] 1.6 Reuse the stateful frame decoder across notification boundaries; verify a test that a single frame delivered as two chunks reassembles and decodes
- [ ] 1.7 Document the session flow in `docs/protocol-a1.md` and verify the documented sequence matches the implemented discovery, requests, and acknowledgements
- [ ] 1.8 Run `Scripts/test-portable.sh` and verify the forbidden-import check, pinned resolution, and both suites pass with the new tests on Linux
- [ ] 1.9 Compute stroke and dot counts from accepted packets and distinct page counts from canonical page identities, never from the `0xA3` summary; verify a fixture where `0xA3` disagrees with the packet stream reports the decoded counts
- [ ] 1.10 Bound response and packet waits, close the transport on failure or cancellation, and reset decoder and assembler state on retry; verify timeout, cancellation, unsupported compression, and retry-after-partial-transfer tests

## 2. CoreBluetooth transport (app target)

- [ ] 2.1 Scaffold `Apps/NeoBridgeMac` as a SwiftPM executable package with a macOS 15.0 target linking `Packages/NeoCore` and `Packages/NeoProtocol`; verify `swift build` succeeds on macOS and `Scripts/test-portable.sh` still passes unchanged
- [ ] 2.2 Implement `CoreBluetoothPenTransport` scanning for the advertised name `Neosmartpen_A1` (never a cached address), connecting, and using the write and notify characteristics; record official SDK or A1 GATT evidence for the characteristic UUIDs and write mode; verify a unit test with an injected fake central asserts discovery-by-name selection, explicit selection when multiple pens match, and outbound byte routing
- [ ] 2.3 Emit inbound chunks in arrival order so a split frame reassembles; verify a unit test feeding two chunks for one frame yields one decoded frame
- [ ] 2.4 Signal disconnect versus interruption by finishing or throwing the inbound stream; verify tests for the normal-finish and thrown-interruption paths
- [ ] 2.5 Declare `NSBluetoothAlwaysUsageDescription` and handle denied permission; verify the denial path reports an error and does not scan, and notification-enablement failure stops before the handshake
- [ ] 2.6 Document the transport adapter and its BLE assumptions in `Apps/NeoBridgeMac/README.md` and verify the document names the advertised name, characteristics, and permission requirement

## 3. SwiftUI menu-bar shell

- [ ] 3.1 Build the menu-bar item and the optional details window; verify the app launches as an accessory (`LSUIElement`) app and the window opens from the menu
- [ ] 3.2 Present scanning, connection, verification, sync, and terminal states and, after a complete sync, decoded stroke, dot, and distinct page counts plus the notes read; verify a preview or unit test with a stubbed session shows each state and the final counts
- [ ] 3.3 Present a human-readable error and a retry action; verify a stubbed failed session shows the error and that retry starts a new scan
- [ ] 3.4 Label the retrieval action as reading pen data and results as not saved; verify the completed-sync view states that nothing was written to disk or exported
- [ ] 3.5 Document the shell's states and commands in `Apps/NeoBridgeMac/README.md` and verify the document matches the implemented menu commands
- [ ] 3.6 Add cancellation of an active scan or sync and ensure a failed transfer never appears complete; verify a stubbed partial transfer shows failure and cancellation returns to idle

## 4. Mac build and packaging

- [ ] 4.1 Add `Scripts/remote-mac-build.sh` that builds the portable packages, runs `Scripts/test-portable.sh`, builds the app, and assembles a `NeoBridgeMac.app` bundle with an executable in `Contents/MacOS` and an `Info.plist` carrying bundle identity, `LSUIElement`, and `NSBluetoothAlwaysUsageDescription`; verify the script exits 0 on macOS and produces a launchable bundle with these entries
- [ ] 4.2 Have the script run and record a successful `xcodebuild` of the app's actual scheme from its package or project location; if a package scheme cannot be resolved, provide a minimal project or workspace rather than count a `swift build` fallback as the Xcode gate; verify the recorded Xcode build succeeds
- [ ] 4.3 Document the Mac build and run steps in `AGENTS.md` and `docs/portable-verification.md`; verify the documented commands run as written

## 5. Physical A1 acceptance

- [ ] 5.1 Add `Tests/Hardware/README.md` with a checklist covering each `pen-session`, `macos-ble-transport`, and `macos-app-shell` scenario; verify every scenario in the three specs appears with a pass/fail column
- [ ] 5.2 Confirm the M0 gate conditions in `docs/protocol-a1.md` still hold before running acceptance, and verify the gate section states the gate is open with the evidence reviewed
- [ ] 5.3 Run the connect-and-sync acceptance against a physical A1; verify the app decodes the offline transfer, the page and point counts match the known mark, no `0x25` or `0x27` command was sent, and a second read of the same note still returns the known mark after the traced `next-and-reserve` option; verify a second discovered note can still be requested after the first transfer's Stop acknowledgement, and if the pen has only one note, record the multi-note case as unverified rather than claim it passed
- [ ] 5.4 Record the acceptance run (date, host, OS, pen firmware, protocol version) in `docs/protocol-a1.md` and `Tests/Hardware/README.md`, and verify cleanup remains `keepOnPen` (`PenCleanupPolicy.deletionEnabled == false`)

## Workflow follow-up

- Archive this change after the review requirements are satisfied and the portable suites pass.
- Sync the delta specs into `openspec/specs/` when archiving so the new capabilities land in the main inventory.
