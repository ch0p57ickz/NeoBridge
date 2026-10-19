# Proposal

## Why

The M0 protocol spike is complete and the portable codec now parses real A1
responses, but no application has ever held a live session with the pen:
`Apps/NeoBridgeMac` does not exist, so the verified handshake and
offline-retrieval path has only run from test scripts. This change adds the
smallest end-to-end slice that turns the verified protocol into a working macOS
app — connect, verify the pen, retrieve offline strokes, and report the result —
so physical A1 acceptance can run against a real build (task 4.3 of
`initialize-portable-neocore-neoprotocol-packages`).

## What Changes

- Add `Apps/NeoBridgeMac`, a SwiftUI menu-bar application targeting macOS 15.0,
  the floor set by `Packages/NeoProtocol`'s `Synchronization.Mutex` dependency.
- Add a portable pen session to `Packages/NeoProtocol` that runs the connection
  lifecycle — idle, connecting, verifying version, syncing, complete,
  failed — over the existing `PenTransport` contract: it performs the verified
  handshake (`0x01` / `0x81`), gates on `ProtocolVersionPolicy`, discovers
  available notes and pages with `0x21` / `0xA1` and `0x22` / `0xA2`, requests
  offline data for a discovered note (`0x23`), reads the `0xA3` info response,
  streams `0x24` packets
  into `OfflineTransferAssembler`, and acknowledges each packet with `0xA4`
  (Continue until the end packet, then Stop). Because it depends only on
  `PenTransport`, the same lifecycle is exercisable on Linux with
  `FakePenTransport`.
- Add `CoreBluetoothPenTransport` in the app target, the macOS implementation of
  `PenTransport`: scan for the pen's advertised name (`Neosmartpen_A1`, never a
  cached address), connect, discover the write and notify characteristics, and
  forward inbound and outbound bytes.
- Present connection and sync state in a SwiftUI menu-bar item and an optional
  window, including decoded stroke, dot, and page counts plus a recoverable
  error message.
- Add a Mac build entry point and a physical-A1 acceptance checklist, and
  declare the Bluetooth usage description the app needs.
- **Deferred:** durable storage (`Packages/NeoStorage`), export
  (`Packages/NeoExport`), and replay deduplication. Imported counts are shown
  but not persisted yet; this is an in-memory read, not a durable import.
- **Keep-on-pen:** deletion stays disabled. The app sends no `0x25` or `0x27`
  command, and `PenCleanupPolicy.deletionEnabled` remains `false`. Physical
  acceptance must also confirm that a second read remains possible after the
  traced `next-and-reserve` transfer option.
- **No network:** the app is local-first and makes no cloud calls.

## Capabilities

### New Capabilities

- `pen-session`: the portable connection and synchronization lifecycle over
  `PenTransport` — version verification, offline retrieval, acknowledgement,
  lifecycle state, and the keep-on-pen guarantee — testable on Linux with the
  fake transport.
- `macos-ble-transport`: how the macOS app discovers, connects to, and exchanges
  bytes with an A1 over CoreBluetooth.
- `macos-app-shell`: what the SwiftUI menu-bar and window surface presents —
  connection state, sync progress, results, and errors — without owning
  protocol logic.

### Modified Capabilities

None. The portable domain and protocol requirements are unchanged; this change
consumes them.

## Impact

- `Packages/NeoProtocol` gains the portable pen session plus Linux tests driven
  by `FakePenTransport`; the portability boundary still holds, so no Apple
  framework is imported there.
- New `Apps/NeoBridgeMac` target (SwiftUI, CoreBluetooth, and AppKit
  `NSStatusItem` interop) that links `Packages/NeoCore` and
  `Packages/NeoProtocol` and declares a macOS 15.0 deployment floor.
- New `Scripts/remote-mac-build.sh` as the Mac build and test entry point that
  task 4.3 calls for.
- New `Tests/Hardware` acceptance checklist recording the physical A1 run of
  the connect-and-sync path.
- `docs/protocol-a1.md` and `docs/portable-verification.md` gain the acceptance
  record once the run happens.
- No new third-party dependencies, and no persistence or export in this change.
