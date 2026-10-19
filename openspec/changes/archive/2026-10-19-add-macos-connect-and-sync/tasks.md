# Tasks

## 1. Portable pen session (NeoProtocol)

- [x] 1.1 Add a portable session type in `Packages/NeoProtocol` that consumes `PenTransport` and exposes the `pen-session` lifecycle states and the assembled result; verify a Linux `swift test` drives a session over `FakePenTransport` through idle, connecting, verifying, syncing, and complete in that order, and a rejected default `0x01` connection code fails without trying another code
- [x] 1.2 Gate offline retrieval on the validated-minor policy; verify a test that a validated minor proceeds to `0x21` discovery and a test that an unvalidated minor reports unsupported and sends no offline request
- [x] 1.3 Establish the initial `sectionOwnerId` or documented wildcard needed by `0x21` from official SDK or sanitized A1 evidence; add evidence-backed decoding for `0xA1` note and `0xA2` page lists, with sanitized fixtures; implement `0x21` then `0x22` discovery and form each `0x23` request from discovered identifiers using the traced transfer options and zero page count; verify tests for a discovered note, empty list, malformed list, multiple notes, and missing bootstrap evidence (which must send no list request)
- [x] 1.4 Implement the `0x23` request, `0xA3` read, `0x24` assembly, and `0xA4` acknowledgement (Continue until the end packet, Stop for it); verify a send-responsive transport releases one packet per acknowledgement, checks matching packet IDs and operations, completes a three-packet transfer, fails on nonzero response errors and packet gaps, and reports a stream ending before the end packet as incomplete even if it finishes normally
- [x] 1.5 Keep deletion disabled; verify a test that a completed fake sync sends no `0x25` or `0x27` command
- [x] 1.6 Reuse the stateful frame decoder across notification boundaries; verify a test that a single frame delivered as two chunks reassembles and decodes
- [x] 1.7 Document the session flow in `docs/protocol-a1.md` and verify the documented sequence matches the implemented discovery, requests, and acknowledgements
- [x] 1.8 Run `Scripts/test-portable.sh` and verify the forbidden-import check, pinned resolution, and both suites pass with the new tests on Linux
- [x] 1.9 Compute stroke and dot counts from accepted packets and distinct page counts from canonical page identities, never from the `0xA3` summary; verify a fixture where `0xA3` disagrees with the packet stream reports the decoded counts
- [x] 1.10 Bound response and packet waits, close the transport on failure or cancellation, and reset decoder and assembler state on retry; verify timeout, cancellation, unsupported compression, and retry-after-partial-transfer tests

## 2. CoreBluetooth transport (app target)

- [x] 2.1 Scaffold `Apps/NeoBridgeMac` as a SwiftPM executable package with a macOS 15.0 target linking `Packages/NeoCore` and `Packages/NeoProtocol`; verify `swift build` succeeds on macOS and `Scripts/test-portable.sh` still passes unchanged
- [x] 2.2 Implement `CoreBluetoothPenTransport` scanning for the advertised name `Neosmartpen_A1` (never a cached address), connecting, and using the write and notify characteristics; record official SDK or A1 GATT evidence for the characteristic UUIDs and write mode; verify a unit test with an injected fake central asserts discovery-by-name selection, explicit selection when multiple pens match, and outbound byte routing
- [x] 2.3 Emit inbound chunks in arrival order so a split frame reassembles; verify a unit test feeding two chunks for one frame yields one decoded frame
- [x] 2.4 Signal disconnect versus interruption by finishing or throwing the inbound stream; verify tests for the normal-finish and thrown-interruption paths
- [x] 2.5 Declare `NSBluetoothAlwaysUsageDescription` and handle denied permission; verify the denial path reports an error and does not scan, and notification-enablement failure stops before the handshake
- [x] 2.6 Document the transport adapter and its BLE assumptions in `Apps/NeoBridgeMac/README.md` and verify the document names the advertised name, characteristics, and permission requirement

## 3. SwiftUI menu-bar shell

- [x] 3.1 Build the menu-bar item and the optional details window; verify the app launches as an accessory (`LSUIElement`) app and the window opens from the menu
- [x] 3.2 Present scanning, connection, verification, sync, and terminal states and, after a complete sync, decoded stroke, dot, and distinct page counts plus the notes read; verify a preview or unit test with a stubbed session shows each state and the final counts
- [x] 3.3 Present a human-readable error and a retry action; verify a stubbed failed session shows the error and that retry starts a new scan
- [x] 3.4 Label the retrieval action as reading pen data and results as not saved; verify the completed-sync view states that nothing was written to disk or exported
- [x] 3.5 Document the shell's states and commands in `Apps/NeoBridgeMac/README.md` and verify the document matches the implemented menu commands
- [x] 3.6 Add cancellation of an active scan or sync and ensure a failed transfer never appears complete; verify a stubbed partial transfer shows failure and cancellation returns to idle

## 4. Mac build and packaging

- [x] 4.1 Add `Scripts/remote-mac-build.sh` that builds the portable packages, runs `Scripts/test-portable.sh`, builds the app, and assembles a `NeoBridgeMac.app` bundle with an executable in `Contents/MacOS` and an `Info.plist` carrying bundle identity, `LSUIElement`, and `NSBluetoothAlwaysUsageDescription`; verify the script exits 0 on macOS and produces a launchable bundle with these entries
- [x] 4.2 Have the script run and record a successful `xcodebuild` of the app's actual scheme from its package or project location; if a package scheme cannot be resolved, provide a minimal project or workspace rather than count a `swift build` fallback as the Xcode gate; verify the recorded Xcode build succeeds
- [x] 4.3 Document the Mac build and run steps in `AGENTS.md` and `docs/portable-verification.md`; verify the documented commands run as written

## 5. Physical A1 acceptance

- [x] 5.1 Add `Tests/Hardware/README.md` with a checklist covering each `pen-session`, `macos-ble-transport`, and `macos-app-shell` scenario; verify every scenario in the three specs appears with a pass/fail column
- [x] 5.2 Confirm the M0 gate conditions in `docs/protocol-a1.md` still hold before running acceptance, and verify the gate section states the gate is open with the evidence reviewed
- [x] 5.3 Run the connect-and-sync acceptance against a physical A1; verify the app decodes the offline transfer, the page and point counts match the known mark, no `0x25` or `0x27` command was sent, and a second read of the same note still returns the known mark after the traced `next-and-reserve` option; verify a second discovered note can still be requested after the first transfer's Stop acknowledgement, and if the pen has only one note, record the multi-note case as unverified rather than claim it passed
  - **Run on 2026-10-19 against a physical A1** (`NWP-F151`, firmware `3.00`, protocol `2.23`),
    from the built bundle via the headless acceptance mode in `Tests/Hardware/README.md`.
    Twelve reads completed, including four consecutive reads of the same note and three more
    after the fixes below landed. The transfer assembled 608 packets and 19 pages of note 700;
    on a post-fix read the totals were 6,953 strokes and 70,709 dots, and page 1's first 15
    strokes carry 152 dots bounded by x 1468..3949 and y 698..892, which is the mark recorded
    on 2026-10-18. The second read of the same note returned the same mark, so
    `next-and-reserve` left the strokes on the pen. The outbound command list of every run
    contains only `0x01`, `0x21`, `0x22`, `0x23`, and `0xA4`. The pen lists one note, so the
    multi-note case is recorded as **unverified** in `Tests/Hardware/README.md`, not as passed.
  - **Three defects were found by this run and are fixed.** The scan window was two seconds while
    the pen's first advertisement after a scan started arrived as late as 2.5 seconds, so about
    half of all reads reported no pen while the pen was in range; the window is now thirty
    seconds at most, sized for a pen that has just been switched on, and settles one second after
    the first match. A completed read also left the pen connected, so the app's own next read
    could not find it; an attempt now releases the link when it ends. A read started right after
    the pen was switched on reported no pen found, because the pen does not advertise for several
    seconds after power-on.
  - **Rows not reached** — a second pen, a Bluetooth toggle, a denied permission prompt, a
    mid-transfer interruption, and the SwiftUI shell — are recorded as unverified with their
    reasons in `Tests/Hardware/README.md`.
- [x] 5.4 Record the acceptance run (date, host, OS, pen firmware, protocol version) in `docs/protocol-a1.md` and `Tests/Hardware/README.md`, and verify cleanup remains `keepOnPen` (`PenCleanupPolicy.deletionEnabled == false`)
  - **Recorded.** The run record is in `Tests/Hardware/README.md`, and the result table is in the
    `## App acceptance run (2026-10-19)` section of `docs/protocol-a1.md`: date 2026-10-19, host
    `Jamess-MacBook-Pro-M4.local`, macOS 27.2, Xcode 27.1, pen `NWP-F151`, firmware `3.00`,
    protocol `2.23`.
  - **Cleanup stayed on the pen.** `PenCleanupPolicy.deletionEnabled` is still hard-coded `false`
    in `Packages/NeoCore/Sources/NeoCore/PenDomainInterfaces.swift`, and the acceptance run's own
    packet log carries no `0x25` or `0x27`.

## 6. Acceptance tooling and corrections from the hardware run

- [x] 6.1 Add a headless acceptance mode to the app binary, selected by `NEOBRIDGE_ACCEPTANCE_TRACE`, that drives the same controller the user interface uses and writes a transcript of the attempt; verify `NeoBridgeAcceptanceTests` is not needed because the transcript is produced by the app's own transport decorator, `PenTracingTransportTests` covers the decorator and the transcript format, and running the bundle with the variable set exits 0 for a completed read and 1 for a failed one
- [x] 6.2 Record every outbound frame decoded to its command identifier, every inbound chunk by size, each lifecycle state, and the per-note, per-page, and per-stroke counts in the transcript; verify a completed read's transcript carries the version, the note identity, the stroke and dot counts, and an `outboundCommands` line that lists every command sent
- [x] 6.3 Wait, within a bounded grace window, for an adapter state CoreBluetooth has not resolved yet, instead of reporting it as unavailable; verify tests that a late-resolving state still scans and a state that never resolves is reported without scanning
- [x] 6.4 Size the scan window for the A1's bursty advertising and settle it shortly after the first match; verify tests that a single pen does not wait out the whole window, that a pen whose first advertisement arrives late is still found, and that a pen silent for the whole window is reported as missing
- [x] 6.5 Release the pen when an attempt ends, so a completed read does not leave the link up and block the next read; verify `BluetoothPenSyncRunnerTests` asserts the transport is closed after a completed read and that four consecutive hardware reads each found the pen advertising again
- [x] 6.6 Record the acceptance run in `Tests/Hardware/README.md` and `docs/protocol-a1.md`, and extend the checklist for the scenarios this run added; verify every scenario in the three specs appears in the checklist with a pass/fail column
- [x] 6.7 Size the wait-when-nothing-is-seen scan window for a pen that has just been switched on, and derive the setup deadline from the window so the deadline cannot fire first and report a setup timeout for a read that was still scanning; verify a test asserting the window covers the powered-on delay, a test asserting the derived deadline outlasts the window, and a read against the physical pen started immediately after it is switched on

  - The read started with the pen confirmed off by an on-screen prompt and switched on again once the scan was already running. An independent scanner saw nothing for the first 6.3 seconds of its own scan, then saw the pen; the read completed (646 outbound frames, 7,344 strokes, 74,659 dots) and its outbound commands are only `0x01`, `0x21`, `0x22`, `0x23`, `0xA4`. The pen became visible about three seconds into the scan, so this run verifies the wait-and-catch behaviour but not the need for a longer window: the earlier observation of a switch-on still invisible after six seconds stays the reason for the thirty-second maximum.

## Workflow follow-up

- Archive this change after the review requirements are satisfied and the portable suites pass.
- Sync the delta specs into `openspec/specs/` when archiving so the new capabilities land in the main inventory.
