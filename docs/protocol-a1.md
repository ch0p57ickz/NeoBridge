# M0 A1 protocol spike

This document is the gate for UI implementation. NeoBridge does not start UI work
until the offline retrieval trace below is completed on a physical A1 and
reviewed.

Status: **complete.** The physical A1 capture was performed on 2026-10-18, and the
pen owner reviewed the evidence the same day. The device record and result tables
below record what the capture established.

## Device record

| Field | Value |
| --- | --- |
| Pen model | Neo Smartpen A1, `NWP-F151` (version payload and the Device Information Service `0x2A24` agree) |
| Pen firmware | `3.00` (version payload and DIS `0x2A26` agree) |
| Reported protocol version | `2.23` |
| Reported sub-name | `Neosmartpen_A1` |
| Device type | `0x0001` |
| Pressure sensor type | `0x04` |
| Compression capability | Clear (`0x00` at version payload index 69), so the pen streams uncompressed offline data |
| Connection code | 16 zero bytes, the SDK default, which the pen accepted for `VERSION_INFO`; this unit is not passcode-protected for that request |
| Capture date | 2026-10-18 local (PDT); 2026-10-19 UTC |
| Capture host | Linux host with a USB BLE adapter (`hci0`), driven with the `bleak` library |
| App version | Not applicable, the capture used a spike harness rather than a built app |
| Serial number, Bluetooth address | Recorded only in the raw capture, which stays git-ignored |

The pen advertises as `Neosmartpen_A1` with a random static address that changes on
every power cycle, so it must be matched by advertised name rather than by address.

The A1 is listed as a supported device by Neo's official iOS SDK 3.0, and that SDK
declares protocol version `2.18` in its `VERSION_INFO` request. That establishes
the protocol family. It does not establish the firmware or protocol version of the
pen under test, which is why those rows come from the capture.

## Protocol facts established from official SDK wire evidence

Source: Neo iOS SDK 3.0, commit `a53a01e`
(`https://github.com/NeoSmartpen/iOS-SDK3.0`).

### Framing

| Fact | Value | Source |
| --- | --- | --- |
| Start-of-frame marker | `0xC0` | `NISDK3/Classes/Common/Global.swift` |
| End-of-frame marker | `0xC1` | `NISDK3/Classes/Common/Global.swift` |
| Byte-stuffing escape | `0x7D`, then the byte XOR `0x20` | `NISDK3/Classes/Util/FunctionUtil.swift` (`makeWholePacket`) |
| Frame body | command (1 byte), optional error code (1 byte), length (UInt16 little-endian), payload | `NISDK3/Classes/PenController/PenCommParser.swift` (`parsePenDataPacket`) |
| Integers | Little-endian | `NISDK3/Classes/Util/FunctionUtil.swift` |

### Which frames carry an error code

`parsePenDataPacket` advances past an error code before it reads the length for every
identifier it parses as a response. In `PenCommand` those are the `response*` cases:
`0x81`-`0x87`, `0x91`, `0xA1`, `0xA2`, `0xA3`, `0xA4`, `0xA5`, `0xA7`, `0xB1`,
`0xB2`, `0xC1`, and the log responses `0xF4` and `0xF5`. Event frames, requests, and
the pen's offline data frame omit it.

The capture confirms the rule in both directions:

- `0x81` (`RES_VERSION_INFO`, pen to host) carries it, as
  `c0 81 00 46 00 <70 bytes> c1`: command, error `0x00`, then a length of `0x0046`.
- `0xA4` (`RES2_OFFLINE_DATA`, host to pen) carries it. The acknowledgement is
  `a4 00 03 00 <packet id> <transfer op>`, and the pen accepted all 604 of them.
- `0x24` (`REQ2_OFFLINE_DATA`, pen to host) omits it. The frame is
  `24 <length> <payload>`.

A decoder that always reads the length immediately after the command therefore
mis-parses every response frame, reading `0x81 00 46 00` as a declared length of
`0x4600`.

### Version reporting

`RES_VERSION_INFO` (`0x81`) carries a 70-byte payload: device name (16 bytes),
firmware version (16), protocol version text (8), sub-name (16), device type (2),
Bluetooth address (6), pressure sensor type (1), and, for protocol `2.22` and later,
a compression capability byte at index 69.

The traced pen reports protocol `2.23`, while the SDK declares `2.18`. The declared
value is the version the SDK was built against; the reported value is what the
connected pen runs, and the reported value is the one that has been validated
against hardware.

The compression capability byte, not the protocol version or the payload length,
determines whether the pen compresses offline transfers. This pen reports protocol
`2.23` with the capability byte clear, so a version-based inference would wrongly
report compression support.

### Command identifiers

The full command table is in `NISDK3/Classes/Model/CMD.swift` and is mirrored by
`PenCommand` in `Packages/NeoProtocol`.

### Pen battery and storage state

A separate physical NWP-F151 probe on 2026-10-19 established this exchange after
the accepted `0x01` handshake. The A1 does not expose the standard BLE Battery
Service (`0x180F`); these values come from the pen protocol. The host sent the
zero-payload request `c0 04 00 00 c1` and the pen returned `0x84` with error
code zero and a 64-byte payload. Neo iOS SDK 3.0 names this pair
`REQ_PEN_STATE` / `RES_PEN_STATE`.

| Payload offset | Meaning | Physical probe |
| --- | --- | --- |
| 15 | `memoryUsed`, percent of onboard storage in use | 10% |
| 20, bits 0–6 | `battLevel`, battery percent | 94% |
| 20, bit 7 | Charging flag | Clear (not charging) |

The payload offsets exclude the frame's command, error code, and length.
Production decoding requires exactly 64 payload bytes and percentages no greater
than 100. This probe verifies the query and layout; the macOS app's end-to-end
display still requires a Mac runner build and physical acceptance run.

### Offline discovery and list layouts

The offline read path starts with a list request whose layout needs a starting
`sectionOwnerId`. The capture summary does not record the value the spike harness
supplied, so the official SDK settles it: `REQ.OfflineNoteList` initializes
`sectionOwnerId` to `0xffffffff` and never changes it, so the SDK asks for every
note rather than for one section and owner. `0x21` therefore has a documented
wildcard, and no identifier has to be guessed.

`FunctionUtil.toSectionOwner` packs the pair as `(UInt32(section) << 24) | owner`,
with the owner in the low 24 bits. `toSetionOwner` is the inverse.

| Frame | Payload |
| --- | --- |
| `0x21` request | `sectionOwnerId` (4), `0xffffffff` for every note |
| `0xA1` response | count (2), then per note: `sectionOwnerId` (4), note id (4) |
| `0x22` request | `sectionOwnerId` (4), note id (4) |
| `0xA2` response | `sectionOwnerId` (4), note id (4), page count (2), page ids (4 each) |
| `0xA3` response | stroke count (4), uncompressed size (4), compression flag (1) |

Source: Neo iOS SDK 3.0 `RequestStruct.swift` (`REQ.OfflineNoteList`,
`REQ.OfflinePageList`, `REQ.OfflineData`), `ResponseStruct.swift`
(`OfflineNoteList`, `OfflinePageList`, `OfflineInfo`), and `FunctionUtil.swift`.

The SDK reads these lists without bounds checks. NeoBridge validates the declared
count against the payload first and reports a short list as malformed, because a
partially decoded list would silently hide notes: retrieval stops before `0x23`
rather than continuing with a subset.

### Page identity

`PageInfo` (`0x64`, `0x6B`) carries owner (24 bits), section (1 byte), book
(4 bytes), and page (4 bytes). `0x6B` payloads carry a leading event count.

### Dot payload

`Dot` (`0x65`, `0x6C`) carries a time delta in milliseconds, raw pressure,
x and y as a 16-bit integer part plus a two-digit fractional part, tilt, and
twist. Offline dots append two reserved bytes and a checksum that is the sum of
the preceding bytes truncated to one byte.

### Offline data packet

`OffLineData` is the 18-byte header the pen streams for offline strokes: packet id
(2 bytes), compression flag (1), size before compression (2), size after compression
(2), transfer position (1), owner (3), section (1), book (4), and stroke count (2).
It is followed by 27-byte stroke records, each followed by its 16-byte offline dots.
The transfer position values come from the SDK's `OfflineTransPosition`: 0 start,
1 middle, 2 end.

The pen sends the data as `REQ2_OFFLINE_DATA` (`0x24`), one packet per host
acknowledgement. The SDK models the payload under the `0xA4` (`RES2_OFFLINE_DATA`)
name, but `0xA4` is the host's acknowledgement, not the pen's data frame. The traced
pen sent 604 `0x24` packets and never sent the payload on `0xA4`.

A request's `length` excludes the command and the error code, which request frames
omit. From `RequestStruct.swift`:

| Request | Payload |
| --- | --- |
| `0x21` | sectionOwnerId (4 bytes) |
| `0x22` | sectionOwnerId (4), noteId (4) |
| `0x23` | transOption (1), zipOption (1), sectionOwnerId (4), noteId (4), pageCnt (4), page (4 × pageCnt) |

Three further traps, all confirmed on hardware:

- The pen splits a large `0x24` frame across BLE notifications, so frame assembly
  must be stateful over the whole notification stream rather than per notification.
- The page filter in a `0x23` request does not subset the `0xA3` info response,
  which reports the note total either way.
- The `0xA3` counts are a lagging index and must not be treated as exact. Both
  sessions reported 6,918 strokes and 1,309,538 bytes, while the packet stream
  carried 6,920 strokes and 1,310,024 bytes: exactly two more stroke records and
  their 27 dots. Count what arrives; the stream is authoritative.

## Command evidence table

`Packages/NeoProtocol/Sources/NeoProtocol/CommandEvidence.swift` is the
authoritative table. Summary:

| Category | Commands | Level | Production use |
| --- | --- | --- | --- |
| Handshake | `VERSION_INFO` `0x01`, `RES_VERSION_INFO` `0x81` | official SDK + fixture | allowed |
| Pen events | `0x63`, `0x69`, `0x6A`, `0x64`, `0x6B`, `0x65`, `0x6C` | official SDK + fixture | allowed |
| Offline read | `0x21`, `0x22`, `0x23`, `0x24`, `0xA3`, `0xA4` | official SDK + fixture | allowed |
| Offline deletion | `0x25`, `0x27` | official SDK | gated on the deletion evidence; refused while any verdict is not `safe`, and the recorded deletion-scope verdict is `unsafe` |
| SoundPen and log | `0x73`, `0x74`, `0x75`, `0x76`, `0x77`, `0xF4`, `0xF5` | provisional | inspection only |
| Authentication | `0x02`, `0x03` | none | unsupported |
| Everything else | — | none | unsupported |

A provisional mapping cannot authorize a production request and cannot emit a
completed domain stroke. An unknown command identifier or an unvalidated protocol
version returns an unsupported result.

Independently of the registry, the handshake and the offline read commands were
exercised against a physical A1. The trace below records the exchange.

## Offline retrieval trace

Performed with the pen connected on 2026-10-18. The raw exchange is recorded with
sensitive fields removed and stays git-ignored.

1. Recorded the model, firmware, and protocol version from `RES_VERSION_INFO`
   (`0x81`).
2. Wrote a known test mark, the word "Testing", on page 1 of a NeoLab N notebook,
   and recorded that page's Ncode tuple by hand.
3. Reconnected and requested the offline note list (`0x21`), the page list
   (`0x22`), and offline data (`0x23` with `transOption` next-and-reserve,
   `zipOption` none, and a page count of zero).
4. Read the `0xA3` (`RES1_OFFLINE_DATA_INFO`) response, then acknowledged each
   `0x24` data packet with `0xA4`: `Continue` until the packet reporting transfer
   position `2` (end), which was acknowledged with `Stop`.
5. Assembled the packets with `OfflineTransferAssembler` and decoded the strokes.
6. Compared the decoded page tuple and the ordered point sequence against the
   known test mark.
7. Confirmed that no deletion request (`0x25`, `0x27`) was sent.

### Result

| Check | Result |
| --- | --- |
| Decoded page matches the page written on | Yes. The transfer spans 19 pages (1 and 16-33) of note 700, section 3, owner 27. Page 1, the page the mark was written on, is present. |
| Point sequence matches the known mark | Yes. Page 1 holds 15 strokes and 152 dots bounded by x 1468..3949 and y 698..892. The first 13 strokes are one left-to-right word written in three seconds, with two wide top horizontal strokes consistent with the crossbars of `T` and `t`, and the pen owner confirmed it reads "Testing". |
| Every decoded dot passes the pen's own checksum | Yes, 70,199 of 70,199 dots |
| Decoded transfer | 604 packets, 6,920 strokes, 70,199 dots, in a single transfer that ended at transfer position `2` |
| No deletion request sent | Yes, `0x25` and `0x27` were never sent |
| Pen cleanup mode | That build requested no cleanup, so the pen kept its copy. Deletion is unreachable in every build: `PenCleanupPolicy.deletionEnabled` derives from the deletion evidence gate, whose recorded deletion-scope verdict is `unsafe` |
| Evidence reviewed by | Jimmy, 2026-10-18 |

## Pen session flow

`Packages/NeoProtocol/Sources/NeoProtocol/PenSession.swift` drives the sequence.
It exchanges bytes only through `PenTransport`, so the same flow runs against
`FakePenTransport` on Linux and against the app's `CoreBluetoothPenTransport`.
The documented order below is the order the session sends and reads, and
`PenSessionTests` asserts each step against the sanitized fixtures.

1. Send `0x01` with the SDK default connection code: sixteen zero bytes, app type
   `0x1211`, the application version, and declared protocol `2.18`. Read `0x81`.
   - A non-zero error code means the pen refused the default code. The session
     reports the pen as protected or unsupported and stops. It never tries
     another code.
   - Otherwise compare the reported protocol version against
     `ProtocolVersionPolicy`. An unvalidated minor stops the session before any
     offline request.
2. Send `0x21` with the documented `0xffffffff` wildcard. Read `0xA1` and decode
   the note list.
   - A malformed list stops the session before `0x23`.
   - An empty list completes the session with zero counts, and no `0x23`.
3. For each discovered note, in the order the pen returned them:
   1. Send `0x22` with the discovered `sectionOwnerId` and note id. Read `0xA2`
      and decode the page list.
   2. Send `0x23` with `transOption` next-and-reserve, `zipOption` none, the
      discovered identifiers, and a page count of zero, as in the trace.
   3. Read `0xA3` and keep the summary for diagnostics only.
   4. Read `0x24` packets, one per acknowledgement. Assemble them with a fresh
      `OfflineTransferAssembler` per note, and after each accepted packet send
      `0xA4` with that packet's identifier: Continue for every packet, Stop for
      the end-position packet.
      - A packet gap, a malformed packet, a non-zero response error, or an
        unsupported compressed payload fails the session.
      - A stream that ends before the end-position packet is an incomplete
        transfer, even when it ends normally.
4. Report stroke and dot counts from the accepted `0x24` packets and distinct
   pages from their canonical page identities. The `0xA3` summary is never the
   final result; see the lagging-index note above.

Every wait is bounded. Cancellation, timeout, interruption, and failure close the
transport, and a retry starts a new session with fresh framing and assembly
state. The session sends no `0x25` or `0x27` command, and the evidence table gates
both behind the deletion evidence, so neither can even be encoded.

## Offline transfer option

`0x23` (`REQ_OFFLINE_DATA`) carries a `transOption` byte. The SDK documents three
values, two of which leave the note's data in place:

| Option | Value | Documented meaning |
| --- | --- | --- |
| `notNextTransfer` | `0x00` | Leave the note's data untouched |
| `nextAndReserve` | `0x02` | Keep the note's data so a later read still finds it |
| `nextAndDelete` | `0x01` | Delete the transferred data as part of the transfer |

This build sends `nextAndReserve` (`0x02`) with `zipOption` none and a page count
of zero, which is the option every completed physical read used.

`PenRequest.offlineData(for:)` accepts only `OfflineReadTransferOption`, whose
members are `notNextTransfer` and `nextAndReserve`. The deleting option is not a
member of that type, so the read path has no route to it. `PenSessionTests` pins
both bytes and asserts that the session sends the option it was built with.

### Incremental transfer experiment, 2026-10-19

Tasks 1.1-1.3 ran the known-old/known-new experiment against the physical A1. The
pen held 8,087 strokes across 22 pages of note 700, section 3, owner 27, and the
library held those same 8,087 identities, so the whole pen was the known-old set.
Five strokes were then written on page 1 by hand as the known-new set, and the runs
below re-read the pen. Each attempt was a headless acceptance run
(`NEOBRIDGE_ACCEPTANCE_TRACE`) with the option varied by
`NEOBRIDGE_ACCEPTANCE_TRANSFER_OPTION`; each transcript states its own option on its
first line, and the archived transcripts are in
`Tests/Fixtures/raw/acceptance-2026-10-19-transfer-option/`.

| Field | Value |
| --- | --- |
| Date | 2026-10-19 |
| Host | Jamess-MacBook-Pro-M4.local |
| macOS version | 27.2 (26B5112a) |
| Xcode version | 27.1 (27A9275) |
| Pen model | `NWP-F151` |
| Pen firmware | `3.00` |
| Reported protocol version | `2.23`, from the device record |
| App build | `Scripts/remote-mac-build.sh`, release configuration |
| Known-old set | 8,087 fingerprints, from the library snapshot `library-before-mark.sqlite` |
| Known-new set | 5 strokes written on page 1 |
| Transcripts | sanitized packet logs, no Bluetooth address, serial number, or authentication material |

| Run | Option | Observed |
| --- | --- | --- |
| `opt02-a` | `0x02` | 8,092 strokes, 718 `0x24` packets, 718 acknowledgements, final packet 718 with operation Stop; the 5 new strokes are in the returned set |
| `opt02-b` | `0x02`, repeated | identical to `opt02-a`: same counts, same final packet, and a byte-for-byte identical fingerprint set |
| `opt00-a` | `0x00` | the `0xA3` summary arrives (15 bytes) and then no `0x24` packet ever does; the read fails as a timeout with 0 strokes |
| `opt00-abort` | `0x00`, abort armed | identical to `opt00-a`: the interrupt is unreachable because no packet arrives |
| `opt02-abort` | `0x02`, abort when packet 100 arrives | fails after 99 assembled packets: "the transfer ended after 99 packet(s) without an end packet" |
| `opt02-abort-recovery` | `0x02` | 8,092 strokes, 0 duplicates, 8,092 identities identical to `opt02-a` |
| `opt00-abort-recovery` | `0x02` | 8,092 strokes, 0 duplicates, 8,092 identities identical to `opt02-a` |

Conclusions:

- **Neither option is incremental.** Both completed reads returned every stroke,
  including the 5 the library already held, and the repeat returned the identical
  identity set, so `nextAndReserve` does not advance a cursor. Incremental
  behaviour has to come from the host, which is what the library's fingerprint
  deduplication provides.
- **`notNextTransfer` does not transfer at all on this pen.** It answers the `0xA3`
  request and then sends nothing, so it is not a slower or page-scoped read. It has
  a second effect: after the abandoned attempt the pen answered no further `0x23`
  request, for either option, until it was switched off and on again. An abandoned
  `nextAndReserve` transfer did not do that, which is how the two options were told
  apart beyond the packet count.
- **An interrupted `nextAndReserve` transfer loses nothing.** The run that stopped
  after 99 packets was followed by a read that returned every stroke, including the
  5 that no read had imported yet, with identities identical to a completed read.
  This is what the `interruptedTransferRetention` gate condition asks for, for this
  option on this pen; recording it as a verdict belongs to the deletion tasks, and
  the gate stays closed until all four conditions and a command scope are settled.
- **`nextAndReserve` remains the only option this build may send**, and the only
  one with completed-transfer evidence.

The experiment read the pen twice with each option, so the cursor question is
settled by repetition rather than by one read.

## Deletion experiment, 2026-10-20

The deletion evidence gate needs physical traces of `0x25` and `0x27`. Neither can be
sent from the app: `PenCommand.frameKind` returns `nil` for both, so the portable
encoder refuses to frame them and no shipped binary can reach them. The experiment
therefore ran through `Tests/Hardware/PenLab`, a macOS-only package that carries its
own codec for exactly these two frames and lives outside every app target. It sends
nothing without `--send`, it names the subject of each step in its transcript, and it
records no payload except a deletion answer, because the version response carries the
pen's Bluetooth address.

| Field | Value |
| --- | --- |
| Date | 2026-10-20 |
| Pen model | `NWP-F151` |
| Pen firmware | `3.00` |
| Reported protocol version | `2.23` |
| Tool | `Tests/Hardware/PenLab`, assembled by `Scripts/pen-lab-build.sh` |
| Subject | note 700, section 3, owner 27 — the note the transfer-option experiment read |

Three runs made up the experiment, and a normal acceptance read closed it. The
transcripts are sanitized and git-ignored under
`Tests/Fixtures/raw/acceptance-2026-10-20-deletion/`.

| Run | Transcript | What it asked the pen |
| --- | --- | --- |
| probe | `probe-0x25-0x27-raw.txt` | both commands, aimed at note 999 and at page 1 of note 999, which the pen does not hold |
| page delete | `delete-page-1.txt` | page 1 of note 700, the page the mark was written on |
| note delete | `delete-note-700.txt` | every stroke of note 700 |
| read afterwards | `read-after-delete.txt` | a normal `nextAndReserve` read, with cleanup kept on the pen |

The probe was re-run with the tool revision that prints a response body verbatim, so
`probe-0x25-0x27-raw.txt` carries `body=` and `declaredLength=` lines. The two delete
transcripts predate those lines and record the command, the error code, and the
payload; their frames and answers have the same shape.

### Framing and what the answers mean

| Step | Request frame | Answer | Reading |
| --- | --- | --- | --- |
| `0x25` on note 999 | `C02509001B00000301E7030000C1` | body `A500010000`, error `0x00`, declared length 1, payload `00` | the frame layout was accepted, and the pen reported that it removed nothing |
| `0x27` on page 1 of note 999 | `C0270D001B000003E70300000101000000C1` | body `A7050000`, error `0x05`, declared length 0, payload empty | refused with `NotSupportCMD` |
| `0x25` on note 700 | `C02509001B00000301BC020000C1` | error `0x00`, payload `01` | the same layout, accepted, with one removal reported |
| `0x27` on page 1 of note 700 | `C0270D001B000003BC0200000101000000C1` | error `0x05` | refused for a note the pen does hold as well |

Both requests use the layout Neo iOS SDK 3.0 documents (`NISDK3/Classes/Model/RequestStruct.swift`):
a request body is the command, a little-endian `UInt16` length, the packed section and
owner, the note identifiers, and a count. `0x25` names notes; `0x27` names one note
and pages. Neither takes a page range, so no request can say "every page of this note"
other than by listing them. The two request frames are pinned byte for byte in
`Tests/Hardware/PenLab/Tests/PenLabTests/PenLabFramesTests.swift`, so a change to their
layout fails there.

Both answers use the response framing the decoder already handles: the command, an
error code, a little-endian `UInt16` length, and the payload. The pen answers an
`0x25` in about 30 ms.

The first payload byte counts the notes whose data went: `00` for note 999, which the
pen does not hold, and `01` for note 700, which it did. The answer therefore reports a
completed removal rather than a bare acceptance, and the read that followed bears it
out. It carries no identifier list behind the count, so a
reader expecting the SDK's count-then-identifiers payload meets a one-byte payload
instead; the lab records that mismatch rather than smoothing it into a reading the
bytes do not support.

`0x27` is a different matter. The pen answers it with error code `0x05`
(`NotSupportCMD`) whether or not it holds the note, so this firmware implements no
page-scoped deletion, and `0x25` is the only deletion command the pen offers.

### What the note delete removed

What the pen held before the command is known from the library rather than from a pen
read: the snapshot `library-before-deletion.sqlite`, taken first, holds 22 pages for
note 700 — page 1 and pages 16 to 36. The pen owner then wrote a mark on page 1 by hand
and left it unread, so that page held delivered strokes and a newer, undelivered one
together. The mark is the pen owner's account, and no transcript shows it, because the
lab never reads the pen.

| Observation | The library snapshot taken first | The read after the command |
| --- | --- | --- |
| Pages of note 700 | 22 — 1 and 16 to 36 | 2 — 36 and 37 |
| Strokes | 8,087 | 346, every one of them new to the library |

The read afterwards imported all 346 as new strokes — no fingerprint in it matches
either snapshot — and the pen owner confirmed they were written **after** the command.
They are therefore new writing rather than survivors, and nothing the pen held when the
command ran is listed afterwards. Page 36 shows that directly: it was one of the 22
pages, and every stroke now on it is new, so the strokes it held before the command were
removed. Page 1 is gone entirely, and the owner's account is that the mark went with the
delivered strokes.

The library was never in the request path, and it kept everything: the snapshots taken
before the deletion and after it both list 22 pages, the read afterwards added all 346
strokes as new ones, and the cleanup journal stayed empty because the run kept the pen's
copy.

### Verdicts this trace records

| Condition | Verdict | What the trace shows |
| --- | --- | --- |
| `payloadFraming` | `safe` | both request layouts were parsed and both answers carry the command, an error code, a little-endian length, and a payload. `0x25` was accepted; `0x27` was parsed and refused |
| `responseMeaning` | `safe` | the first payload byte counts the notes whose data went, `00` for a note the pen does not hold and `01` for one it does, and the following read confirms the data was gone |
| `deletionScope` | `unsafe` | the pen refuses the page-scoped command (`0x27` → `0x05`), so the only deletion it accepts takes a whole note, and the `0x25` run removed that note's 22 delivered pages. No command this firmware accepts can remove a read's verified data while leaving a newer stroke on the same note |
| `interruptedTransferRetention` | `safe` | the 2026-10-19 experiment (`opt02-abort`, `opt02-abort-recovery`) interrupted a `nextAndReserve` read after 99 packets, and the next read returned all 8,092 identities, including the 5 that no read had imported |

One command is proven to what it scopes: `0x25` is note-scoped. No trace proves a page
scope, because `0x27` is refused. The gate stays shut all the same, and not for want of
a verdict: `deletionScope` is `unsafe`, so `deletionEnabled` stays false and no
deletion is reachable.

The scope verdict does not rest on the mark. A transcript shows the removal of the
note's delivered pages, and the owner's account is that the mark written afterwards on
page 1 went with them. Either way the pen refuses the page-scoped command, so no command
it accepts can separate a note's newer strokes from the ones a read already holds.
`PenDeletionEvidence.physicalTrace2026_10_20` is that record, and `PenCleanupPolicy`
carries it, so the app reports the deletion scope — rather than a missing trace — as the
reason it kept the pen's copy.

## Deletion evidence gate

The A1 has two offline deletion commands, `0x25` and `0x27`, answered by `0xA5`
and `0xA7`. The SDK documents their identifiers, and this build records them at
`officialSDK` level for that reason. The deletion experiment of 2026-10-20 traced
both against the physical pen, and what it found closes the gate rather than opens
it, so neither may be sent.

`PenDeletionEvidence` turns that into data: `PenCleanupPolicy.deletionEnabled`
derives from it, so opening the gate is a change to the recorded verdicts rather
than an edit to a boolean. Four conditions must each be `safe`, and the trace of
2026-10-20 settles all four:

| Condition | What a trace must establish | Verdict | Citation |
| --- | --- | --- | --- |
| `payloadFraming` | the request payload layout and the response framing that answers it | `safe` | `probe-0x25-0x27-raw.txt`: both requests were framed and answered in that layout, and both answers carry the command, an error code, a length, and a payload |
| `deletionScope` | that the command removes exactly the verified data, including when newer strokes exist on the same page or note | `unsafe` | `delete-note-700.txt` and `delete-page-1.txt`: the pen refuses the page-scoped command with `0x05`, so the only deletion it accepts takes a whole note, and the `0x25` run removed that note's 22 delivered pages. No command it accepts can remove a verified subset of a note |
| `responseMeaning` | whether `0xA5`/`0xA7` means acceptance of the command or completed removal of the requested scope | `safe` | `probe-0x25-0x27-raw.txt` and `delete-note-700.txt`: `00` for a note the pen does not hold, `01` for one it does, and `read-after-delete.txt` confirms the removal |
| `interruptedTransferRetention` | that an interrupted transfer leaves every not-yet-imported stroke retrievable | `safe` | the 2026-10-19 transfer-option experiment (`opt02-abort`, `opt02-abort-recovery`) left all 8,092 identities, including the 5 no read had imported, retrievable |

The proven command scope is `0x25`, note-scoped. `0x27` is refused with `0x05`
(`NotSupportCMD`), so no trace proves a page scope on this firmware. A trace's mere
existence would not open the gate, and this one shows unsafe behavior: it closes the
gate on `deletionScope`. An unsafe verdict is not the same as a missing one, so the
reason a build gives names the scope instead of claiming that no trace exists.
`PenDeletionEvidence.physicalTrace2026_10_20` is that record, and
`PenCleanupPolicy` carries it.

While the gate is closed, `CommandEvidenceRegistry.authorization(for:)` reports
both commands as `.gated` and names the conditions that are not `safe`, so no
deletion frame can be encoded or sent. `VersionAndEvidenceTests` pins the gate: a
proven `note` scope opens `0x25` and leaves `0x27` gated, and an `unsafe` verdict
keeps both closed even when a scope is proven.

## Fixture coverage today

`Tests/Fixtures` holds fourteen sanitized fixtures with recorded provenance,
sanitization, device model, observed protocol version, and expected output:

| Fixture | Covers |
| --- | --- |
| `a1-handshake-version-2.23` | the real handshake: the host's `0x01` request and the pen's `0x81` response reporting `2.23`, Bluetooth address zeroed |
| `a1-version-info-2.18` | version handshake, zeroed Bluetooth address |
| `a1-realtime-stroke` | live down, four dots, up |
| `a1-offline-stroke` | single offline data packet with checksummed dots |
| `a1-offline-multipacket` | three-packet offline transfer on `0x24`, positions start, middle, end |
| `a1-truncated-frame` | truncated frame and recovery |
| `a1-size-limit-recovery` | payload and buffer limits and recovery |
| `a1-escaped-page-identity` | byte-stuffing round trip |
| `a1-offline-note-list` | an `0xA1` note list reporting the captured note 700 and a second note |
| `a1-offline-note-list-empty` | an `0xA1` list with no notes |
| `a1-offline-note-list-malformed` | an `0xA1` list whose count exceeds its entries |
| `a1-offline-page-list` | an `0xA2` page list for the captured note |
| `a1-offline-data-info` | the `0xA3` summary the physical A1 reported |
| `a1-offline-session` | the whole read path in trace order for two notes, with a lagging `0xA3` |

Twelve of these are synthetic reconstructions of the documented wire layout, built by
`Tests/Fixtures/generate-fixtures.py`, which implements the wire format independently
of the Swift codec so the tests cross-check the implementation instead of restating it.
The remaining two, `a1-handshake-version-2.23` and `a1-offline-session`, open with the
version response derived from the recorded handshake above, with the Bluetooth address
field zeroed; the session fixture also carries the captured note identity and the
captured summary values. Neither carries a serial number, and no fixture carries stroke
content from the pen. The full capture is not committed, because its stroke coordinates
are the user's own handwriting. Raw captures belong in `Tests/Fixtures/raw/`, which is
git-ignored.

## Gate

UI implementation may begin only when:

- the device record and offline retrieval trace above are complete — **done**,
- the decoded page and point sequence match the known test mark — **done**,
- no deletion request was sent — **done**,
- and the evidence has been reviewed — **done**, by the pen owner on 2026-10-18.

All four conditions hold, so the gate is open and UI implementation may begin.

## App acceptance run (2026-10-19)

The macOS app's connect-and-sync path was run against a physical A1 from the built
bundle, using the headless mode described in `Tests/Hardware/README.md`. The same
binary, adapter, transport, runner, and portable session performed each read; only
the user interface was skipped. Fourteen reads completed, including four consecutive
reads of the same note, three more after the fixes below landed, and two with the pen
switched off and on again while a scan was already running.

| Field | Value |
| --- | --- |
| Date | 2026-10-19 |
| Host | Jamess-MacBook-Pro-M4.local |
| macOS version | 27.2 (26B5112a) |
| Xcode version | 27.1 (27A9275) |
| Pen model | `NWP-F151` |
| Pen firmware | `3.00` |
| Reported protocol version | `2.23` |
| App build | `Scripts/remote-mac-build.sh`, release configuration |

### Result

| Check | Result |
| --- | --- |
| Handshake and version gate | Yes. `0x01` with the SDK's default connection code drew an `0x81` response carrying `2.23`, `NWP-F151`, firmware `3.00`, and error code zero |
| Discovery and retrieval | Yes. The command order was `0x01`, `0x21` (wildcard `0xffffffff`), `0x22`, `0x23` with `pageCnt` zero, then one `0xA4` per `0x24` |
| Decoded page matches the page written on | Yes. Note 700, section 3, owner 27, with 19 pages (1 and 16-33) |
| Point sequence matches the known mark | Yes. Page 1's first 15 strokes carry 152 dots bounded by x 1468..3949 and y 698..892, which is the mark recorded above; the first 13 of them span 2.6 seconds of pen-origin time |
| Decoded transfer | 608 packets, 6,953 strokes, 70,709 dots in one transfer. The note is still in use, so later reads in the same run carried slightly more (6,974 strokes) and the totals no longer match the 6,920 / 70,199 recorded on 2026-10-18 |
| Every decoded dot passes the pen's own checksum | Yes, no checksum or framing error over 3,053 notification chunks and 1,335,753 inbound bytes |
| Acknowledgement pacing | Yes. 608 `0xA4` frames, one per `0x24` packet, operation `1` (Continue) through packet 607 and `0` (Stop) on packet 608 |
| No deletion request sent | Yes. The outbound command list of every run contains only `0x01`, `0x21`, `0x22`, `0x23`, and `0xA4` |
| Pen cleanup mode | That build requested no cleanup, so the pen kept its copy. Deletion is unreachable in every build: `PenCleanupPolicy.deletionEnabled` derives from the deletion evidence gate, whose recorded deletion-scope verdict is `unsafe` |
| Link released after a read | Yes. Every completed read logged a Disconnected state, and each of four consecutive reads found the pen advertising again |

The run's totals exceed the 6,920 strokes and 70,199 dots recorded on 2026-10-18
because the note has been written to since. The mark itself is unchanged: it is
checked stroke by stroke, not by a total.

Three consecutive reads on the fixed build confirmed the fixes: each logged
Disconnected and each found the pen advertising again. One attempt immediately after
the pen was switched on found nothing, because the pen had not begun advertising
yet; a later attempt in the same minute succeeded.

Three defects were found only by this run and are fixed:

- the scan window was two seconds, and the pen's first advertisement after a scan
  started arrived as late as 2.5 seconds, so roughly half of all reads reported
  that no pen was found while the pen was in range;
- a completed read left the pen connected. A connected pen stops advertising, so
  the app's own next read could not find it, and the pen stayed unavailable to
  its other owners;
- a read started right after the pen was switched on reported that no pen was
  found, because the pen had not begun advertising yet. The wait-when-nothing-is-seen
  window is now thirty seconds, and a matched pen still settles the scan after one
  second.

The third defect was measured afterwards, with the pen confirmed off by an on-screen
prompt and switched on again while a read's scan was already running. An independent
Bluetooth scanner saw no advertisement for the first 6.3 seconds of its own scan and
then saw the pen, so the pen really was silent when the app started scanning; the read
completed with 646 outbound frames, 7,344 strokes, and 74,659 dots, and its outbound
command list contains only `0x01`, `0x21`, `0x22`, `0x23`, and `0xA4`. The pen became
visible about three seconds into the read's scan, which the previous six-second window
would have covered. The switch-on delay is therefore not consistent: it exceeded six
seconds on the first occasion and was about three seconds here. The thirty-second
window covers the slower case, and neither observation shows the pen to be present
when the window has elapsed.

The rows this run could not reach — a second pen, a Bluetooth toggle, a denied
permission prompt, a mid-transfer interruption, and the window behaviour of the user
interface — are recorded as unverified in `Tests/Hardware/README.md`. The details-window
command was reached on first use afterwards and is recorded as passing there, together
with the accessory-app activation defect it exposed. The pen owner then used the app by
hand and reports it working; the remaining hard-to-reach cases above are left out of the
acceptance by decision for now, and the checklist says so where they appear.

The evidence still requires codec corrections, which were tracked separately in
`openspec/changes/archive/2026-10-19-correct-a1-codec-from-hardware-evidence/` before
that change was archived:

- response frames carry an error code between the command and the length, which the
  decoder does not yet handle;
- compression support must be read from the version payload's capability byte, and
  the reported minor `2.23` must join the validated minors.

The multi-packet offline transfer that the capture required is already implemented
and verified. The full 604-packet capture assembles and decodes through
`OfflineTransferAssembler` with no errors.

An open gate does not mean the codec is finished. Until the response-frame
correction lands, the decoder cannot parse a real response, so no application can
hold a live session with a pen. That correction is a prerequisite for connecting,
not for starting UI work.

## Save-and-export acceptance run (2026-10-19)

After the durable library and deterministic export landed, the same headless mode was
run once more against the same pen with an export destination set, so a single read
both committed to the library and published files. It read note 700, section 3, owner
27 across 22 pages: 8064 strokes and 82238 dots, in 711 outbound frames and 3547
inbound chunks. It committed 8064 strokes and published 66 files (22 pages times JSON,
SVG, and Markdown), and exited zero.

| Check | Result |
| --- | --- |
| Durable save | Yes. The library commit added 2 strokes and reported 8062 duplicates, so the strokes already stored from an earlier read were not re-added |
| Deterministic export | Yes, for the files written. All 66 targets published, none failed; every JSON file parsed and every SVG file was well-formed, and all 22 pages declared the same `viewBox="0 0 54.84 88.58"` canvas at `130.0mm x 210.0mm` |
| No device identity in output | Yes. No exported file carries a pen model, firmware, serial number, or Bluetooth address |
| No deletion request sent | Yes. The outbound command list contains only `0x01`, `0x21`, `0x22`, `0x23`, and `0xA4` |
| Pen cleanup mode | That build requested no cleanup, so the pen kept its copy. Deletion is unreachable in every build: `PenCleanupPolicy.deletionEnabled` derives from the deletion evidence gate, whose recorded deletion-scope verdict is `unsafe` |

The per-scenario rows are recorded under "Save-and-export acceptance" in
`Tests/Hardware/README.md`. The byte counts match the files on disk, and the sanitized
transcript holds no Bluetooth address, serial number, or authentication material.
