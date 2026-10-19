# Design

## Context

See `proposal.md` for motivation. The pieces this design has to fit:

- `Packages/NeoProtocol` already provides `PenTransport`,
  `PenFrameDecoder`/`PenFrameEncoder`, `PenEventDecoder`,
  `OfflineTransferAssembler`, `CommandEvidenceRegistry`, and
  `ProtocolVersionPolicy`. The codec parses real response frames and the whole
  604-packet capture assembles cleanly. It does not yet parse the `0xA1` note
  list or `0xA2` page list into requestable identifiers.
- The A1 advertises under the name `Neosmartpen_A1` with a random static
  address that changes across power cycles, splits large `0x24` frames across
  BLE notifications, and sends one data packet per acknowledgement.
- There is no app target today, and `Packages/NeoProtocol` sets a macOS 15.0
  deployment floor, so any app target must match it.
- The M0 gate is open, so UI work may proceed; physical A1 acceptance is still
  outstanding (task 4.3).

## Goals / Non-Goals

**Goals:**

- Run the connect, verify, and offline-retrieve lifecycle on Linux against the
  fake transport.
- Keep the macOS app target a thin adapter: CoreBluetooth and SwiftUI only.
- Produce a buildable app and a repeatable Mac build entry point.
- Make physical A1 acceptance runnable and recordable.

**Non-Goals:**

- Persistence, export, replay deduplication, and deletion.
- Live realtime pen streaming; this slice syncs offline data only.
- Connection codes and authentication (`0x02`, `0x03`), which remain at
  evidence level "none".
- Code signing, notarization, and distribution packaging.

The observed `0x01` handshake uses the SDK's default sixteen-zero connection
code. That is evidence for this unprotected pen only; a pen that rejects it
fails with a clear unsupported/protected-pen error. The session must not guess
or retry other codes.

## Decisions

### Session orchestration lives in the portable package

Add a portable session type to `Packages/NeoProtocol` that consumes
`PenTransport`. It owns the handshake, the version gate, note and page discovery,
the `0x23` request, the `0xA3` read, the `0x24` stream, the `0xA4`
acknowledgements, and the lifecycle states defined in the `pen-session` spec.

The recorded A1 exchange sent `0x21` before `0x22`, then `0x23`. Its checked-in
summary does not record the `sectionOwnerId` supplied to `0x21`, even though
the request layout requires one. First establish from official SDK code or a
sanitized A1 trace how the initial section/owner value is obtained or whether
a documented wildcard is accepted. The session then decodes the `0xA1` note
list to obtain requestable section/owner and note IDs, requests
`0xA2` pages for that note, and sends `0x23` using those discovered IDs with
`transOption` next-and-reserve, `zipOption` none, and page count zero, as in the
trace. It processes each discovered note in the order returned by the pen, with
a fresh assembler and a Stop acknowledgement at the end of each transfer; the
Mac acceptance run must verify that a second note can still be requested after
Stop. If no notes are
returned, it completes with zero counts. Malformed or unsupported list data
fails the session before `0x23`; no guessed IDs or hard-coded notebook tuple
are sent. Before production use, add sanitized `0xA1` and `0xA2` fixtures
with SDK or physical A1 provenance and verify the parser against them.

The trace proves the command order for one note, but the recorded documentation
does not establish the initial `0x21` identifier, the `0xA1`/`0xA2` payload
layout, or multi-note continuation.
If either cannot be established from SDK evidence and a sanitized fixture, fail
closed and leave this task and physical acceptance unchecked. The session must
not silently report a partial note set as a completed pen sync.

*Why:* the sequence is protocol logic, not UI. Living in the portable package
lets it run under `swift test` on Linux with `FakePenTransport`, and it keeps
the app target from becoming a second, untested implementation of the protocol.
*Alternative considered:* orchestration in the app's view model. Rejected
because it would be testable only on macOS and would duplicate framing and
assembly logic that already has Linux coverage.

### The app target is a SwiftPM executable package, bundled by a script

`Apps/NeoBridgeMac/Package.swift` declares a macOS 15.0 executable target that
links `Packages/NeoCore` and `Packages/NeoProtocol`. `Scripts/remote-mac-build.sh`
builds the portable packages, runs their tests, builds the app, and assembles a
`NeoBridgeMac.app` bundle with an executable in `Contents/MacOS` and an
`Info.plist` carrying bundle identity, `LSUIElement`, and
`NSBluetoothAlwaysUsageDescription`. On a Mac with Xcode, the script must also
run a successful `xcodebuild` of the app's actual scheme from its package or
project location and record the invocation. If Xcode cannot resolve a package
scheme, supply a minimal Xcode project or workspace rather than treating
`swift build` as a substitute for the required Xcode check.

*Why:* SwiftPM keeps the portable packages buildable from Linux, while the
explicit `xcodebuild` gate catches app-target issues under Xcode. A bundle is
required because CoreBluetooth reads its
usage description from `Info.plist`, which a bare `swift run` executable lacks.

### Scanning and connection are app-side; the session starts at connecting

`CoreBluetoothPenTransport` owns scanning, peripheral selection by advertised
name, characteristic discovery, and byte forwarding. It implements the portable
`PenTransport` contract and reports disconnects by finishing or throwing the
inbound stream. The session takes over once a transport exists.

*Why:* scanning and GATT discovery are platform APIs with no portable analogue,
while the protocol sequence is host-neutral. *Alternative considered:* pass a
discovery protocol through the fake transport. Rejected as abstraction the
Linux tests do not need.

### Reuse the stateful decoder for notification fragmentation

The transport forwards raw notification chunks; the existing frame decoder
reassembles frames across chunk boundaries.

*Why:* the decoder already handles partial frames and resynchronization, and it
is covered by fixtures. Reimplementing buffering in the app would create a
second framing path to test. *Risk addressed:* a frame split across
notifications must still decode.

### Acknowledgement pacing matches the capture

The session acknowledges each `0x24` packet with `0xA4` (Continue), and the end
packet with Stop, before waiting for the next packet.

The `next-and-reserve` option is the one in the physical trace, but its effect
on subsequent reads is not established by the checked-in evidence. Acceptance
must read the same known note again and confirm its page and point counts remain
available before describing this flow as nondestructive.

*Why:* the physical capture shows one data packet per acknowledgement; batching
or delaying acknowledgements would change the pen's flow control. *Alternative
considered:* acknowledge on a timer. Rejected as unvalidated behavior.

The existing `FakePenTransport` emits all scripted chunks without regard to
outbound sends, so it can check acknowledgement bytes but cannot prove pacing.
Add a send-responsive test transport that releases the first `0x24` packet
after the `0x23` request and each subsequent packet only after a matching
`0xA4` Continue. Assert that the end packet receives Stop and that no later
packet is emitted. Keep the existing fake for fixed fixture replay.

### Threading and deployment floor

CoreBluetooth callbacks run on a dedicated dispatch queue; the session runs as
an async task and guards shared state with a `Synchronization.Mutex` (or an
actor). The app declares macOS 15.0, matching `NeoProtocol`.

*Why:* Swift 6 strict concurrency applies, and `Mutex` is the repo's chosen
primitive. The floor is already set by the package, so the app cannot target
lower.

Bound scan, connect, discovery, handshake, and packet waits with explicit
timeouts. Cancellation and retry close the old transport, stop the scan, reset
the frame decoder and transfer assembler, and start a fresh session. A normal
stream finish before the end packet is still an incomplete transfer. A failed
response, malformed frame, unexpected command, packet gap, or unsupported
compressed transfer fails the session; no partial counts appear as a completed
result.

### Results stay in memory

The app derives stroke, dot, and distinct canonical page counts from the
assembled `0x24` records, not the lagging `0xA3` summary. It displays them as
unsaved and identifies which note transfers completed. Partial counts on
failure are diagnostic only, never a completed result.

*Why:* persistence is deferred, and showing a durable-sounding result would
mislead. The UI must state that nothing was written to disk.

## Risks / Trade-offs

- [The SwiftUI/CoreBluetooth target cannot build on the Linux host] → Keep the
  portable suite as the Linux gate; build the app only from
  `Scripts/remote-mac-build.sh` on a Mac, and record which toolchain ran.
- [Bluetooth permission prompts vary by macOS version] → Declare the usage
  description in `Info.plist`, report denial explicitly, and record the OS
  version in the acceptance notes.
- [The pen's random address changes between runs] → Match the advertised name
  and clear cached peripherals before each scan; never persist an address.
- [Frames split across notifications] → Forward raw chunks to the stateful
  decoder and add a split-chunk test.
- [Hardware availability] → The session and transport are both exercised with
  the fake transport and fixtures first; hardware acceptance is a recorded,
  separate gate.
- [Distribution signing is out of scope] → Build ad hoc for local acceptance;
  note that signing and notarization are follow-up work.

## Migration Plan

Additive: no stored data and no change to existing behavior. If hardware
acceptance fails, the portable packages and their tests remain valid; remove the
app target and build script. Rollback is a revert of this change.

## Open Questions

- Whether to move from the SwiftPM-plus-bundle script to an Xcode project once
  code signing and notarization land. This does not change the specs or the
  task breakdown.
