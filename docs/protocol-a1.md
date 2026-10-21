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
  their 27 dots. Count what arrives; the stream is authoritative. In the
  deleting-transfer runs of 2026-10-21 the counts again described what the pen
  held when the request arrived: 346, then 250, then 150 strokes in the first
  three runs, each equal to the read that *preceded* that run and larger than the
  read that followed it, and 18, 18, then 5 in the three of the re-run, where the
  run that removed nothing makes the preceding and following reads equal instead.

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
| Pen cleanup mode | That build requested no cleanup, so the pen kept its copy. No `0x25` or `0x27` deletion command is reachable: `PenCleanupPolicy.deletionEnabled` derives from the deletion evidence gate, whose recorded deletion-scope verdict is `unsafe`. The deleting transfer (`0x23` option `0x01`) is a separate route with its own record, and it was not part of this run |
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

The ordinary read sends `nextAndReserve` (`0x02`) with `zipOption` none and a page
count of zero, which is the option every completed physical read used.

`PenRequest.offlineData(for:)` accepts only `OfflineReadTransferOption`, whose
members are `notNextTransfer` and `nextAndReserve`. The deleting option is not a
member of that type, so that overload has no route to it; the deleting read is the
separate overload that takes a `PenDeletingReadAuthorization`. `PenSessionTests`
pins both bytes and asserts that the session sends the option it was built with.

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
- **`nextAndReserve` is the option the ordinary read sends.** It is the
  option the 2026-10-19 experiment established, and the ordinary read path can frame
  no other. The SDK's third value, `nextAndDelete` (`0x01`), deletes the data as the
  transfer runs. It was sent on 2026-10-21 to measure what that means — both to a
  completed transfer and to one interrupted at a chosen packet — and it does
  stream a transfer to its end packet just as `nextAndReserve` does. That trace is
  recorded in "Deleting transfer option, 2026-10-21", and it is the evidence behind
  the deleting read's own record, which sends `0x01` only for the recorded pen
  identity, with a requested export, a per-sync confirmation, and durable packet
  storage, committing each packet before acknowledging it.

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
a verdict: `deletionScope` is `unsafe`, so `deletionEnabled` stays false and no deletion
command is reachable.

The scope verdict does not rest on the mark. A transcript shows the removal of the
note's delivered pages, and the owner's account is that the mark written afterwards on
page 1 went with them. Either way the pen refuses the page-scoped command, so no command
it accepts can separate a note's newer strokes from the ones a read already holds.
`PenDeletionEvidence.physicalTrace2026_10_20` is that record, and `PenCleanupPolicy`
carries it, so the app reports the deletion scope — rather than a missing trace — as the
reason it kept the pen's copy.

## Deleting transfer option, 2026-10-21

`0x23` carries a transfer option byte, and the SDK documents a value that deletes the
transferred data as part of the transfer: `NextAndDelete` (`0x01`). The ordinary read
cannot send it, because `OfflineReadTransferOption` has no deleting member and a `0x23`
request built from it can only ask the pen to leave the data alone. The deleting read
reaches it through the authorization-taking overload, and this trace is what that
route's evidence record is built from.

This run sent the deleting option with `Tests/Hardware/PenLab`, whose `next-delete`
experiment drives the transfer itself: it sends the app's offline read order (`0x21`
with the section-owner wildcard, then `0x22` for the note), then `0x23` with option
`0x01`, then acknowledges each `0x24` packet the way the session does. Two differences
from a session remain, and neither is the option: the lab skips the app's `0x04`
pen-state step, and it does not resolve the section owner from the note list the way the
session does, because the experiment is given its target on the command line.
`--abort-at-packet N` withholds the acknowledgement for packet N and closes the link, so a
run can see how much of what the transfer had already handed over stays on the pen when no
further acknowledgement follows.

| Field | Value |
| --- | --- |
| Date | 2026-10-21 |
| Pen model | `NWP-F151` |
| Pen firmware | `3.00` |
| Reported protocol version | `2.23` |
| Tool | `Tests/Hardware/PenLab`, `next-delete`, built by `Scripts/pen-lab-build.sh` |
| Subject | note 700, section 3, owner 27 |
| Transcripts | `Tests/Fixtures/raw/acceptance-2026-10-21-next-delete/` and, for the re-run below, `Tests/Fixtures/raw/acceptance-2026-10-21-next-delete-rerun/` |

The request is the app's own read frame with the option byte changed, so nothing but the
option differs from a read:

| Command | Frame | Note |
| --- | --- | --- |
| `0x23` with `0x01` | `C0230E0001001B000003BC02000000000000C1` | a read sends `C0230E00`**`02`**`001B000003BC02000000000000C1` |

Three runs made up the experiment, each followed by a normal `nextAndReserve` read, which
is the only way to see what the pen still holds. Every run was accepted: the `0xA3` info
arrived with error code `0x00` in all three, and its stroke count matched the inventory
the read **before** the run measured — 346, then 250, then 150 — because the summary
describes the transfer about to start. Each read **after** a run reported the reduced
count, which is what the table below records.

| Run | Transcripts | What it asked the pen | Started with | Pen held afterwards |
| --- | --- | --- | --- | --- |
| baseline read | `read-baseline.txt` | a normal read, to fix the starting inventory | — | 346 strokes, pages 36 and 37 |
| abort at packet 10 | `next-delete-abort-10.txt`, `read-after-abort-10.txt` | option `0x01`, acknowledge packets 1-9, withhold packet 10's acknowledgement, close | 346 strokes | 250 strokes, page 37 only |
| abort at packet 11 | `next-delete-abort-11.txt`, `read-after-abort-11.txt` | acknowledge packets 1-10, withhold packet 11's acknowledgement, close | 250 strokes | 150 strokes, page 37 only |
| full transfer | `next-delete-full.txt`, `read-after-full.txt` | option `0x01`, acknowledge every packet and answer the end packet with Stop | 150 strokes | 0 strokes, no notes |

| Run | Packets received | Packets acknowledged | Strokes received | Strokes removed |
| --- | --- | --- | --- | --- |
| abort at packet 10 | 10 | 1-9 | 110 | 96 |
| abort at packet 11 | 11 | 1-10 | 112 | 100 |
| full transfer | 15 | 1-15, the 15th carrying Stop | 150 | 150 |

Received counts and removals are measured: the packets come from the transcripts, and the
removals from the pen's own inventory before and after each run. The acknowledgement counts
are derived rather than recorded: the archived transcripts predate the lab's `acknowledged=`
field, so each count comes from the recorded packet count together with the `abortAtPacket`
line the run printed, and only the withheld acknowledgement is named in the transcript
itself. The lab records each step it sends by name and size, but the transfer's `0xA4`
acknowledgements were not recorded.

`next-delete-abort-10.txt` was recorded before the lab stopped repeating the frames its own
steps had already consumed, so it carries two extra `inbound other` lines for the `0xA1`
and `0xA2` discovery responses. The frames and the counts are unaffected; later transcripts
in the directory do not carry them, and the lab now records `acknowledged=`, the stroke
count of the packet it withholds, and the end packet's stroke count.

`read-before.txt` is the failed scan that preceded the experiment: the pen was asleep and
advertised nothing, so it is kept as the record of that attempt rather than as a read.

### What the three runs show

- **The deleting option streams like a read.** The pen answers `0xA3` and then sends one
  `0x24` packet per acknowledgement, with `compressed=false`, exactly as it does for
  `nextAndReserve`. Only what happens to the sent data differs.
- **Removal trails the transfer rather than completing it.** In the first run the pen sent
  110 strokes and 96 went; in the second it sent 112 and 100 went. About one packet's worth
  of what the pen had handed over — 14 strokes, then 12 — stayed on the pen, and page 36 was
  among what the first run had already exchanged when it disappeared. Which strokes the
  residue is cannot be read from the transcripts, which carry no per-packet counts; the
  amount is consistent with the withheld packet's own strokes remaining. The re-run below
  records the per-packet counts and measures that equality exactly.
- **Removal is not a whole-note operation.** After the first run the pen listed page 37
  and not page 36, so the removal followed the transferred data rather than the note.
- **A completed transfer removes the note itself.** The read after the full run found no
  notes at all (`result strokes=0 dots=0 pages=0 notes=0`), so the note left the pen's
  inventory together with its data.
- **An abandoned deleting transfer leaves the pen healthy.** The run after each abort was
  accepted immediately, with no power cycle. That is not what `notNextTransfer` did on
  2026-10-19, where an abandoned request left the pen refusing every later `0x23` until
  it was switched off and on.
- **The library was untouched.** Two snapshots are archived beside the transcripts, one
  taken before the runs and one, as a `sqlite3 .backup`, after them. They hold the same
  content: 23 pages, 8,438 strokes, 88,175 points, and an empty cleanup journal. The batch
  rows in the later snapshot record what each read reached — two pages for the 346-stroke
  reads, page 37 for the 250- and 150-stroke reads — and the read after the full transfer
  recorded none, because it found nothing to save. Every stroke the pen held while these
  runs deleted from it stayed readable: the 250 the pen held after the first abort are among
  page 37's 252, and the 94 it held on page 36 among that page's 266. The earlier snapshot
  is a direct copy rather than a `sqlite3 .backup`, so it reflects the library's last
  checkpoint; the totals it holds are the same as the later snapshot's.

### Re-run with the packet counts recorded, 2026-10-21

The first three runs could only report how much was removed in total, because the lab's
transcripts carried no per-packet counts, and the identification of the residue with the
withheld packet was an inference. The lab now records `acknowledged=`, the stroke count of
the packet it withholds, and the end packet's stroke count, so the same experiment was run
again against fresh handwriting: 18 strokes the pen's owner wrote on pages 36 and 37, which
a read imported first.

| Run | Transcripts | What it asked the pen | Pen held afterwards |
| --- | --- | --- | --- |
| baseline read | `read-baseline.txt` | a normal read, to import the new strokes | 18 strokes, pages 36 and 37 |
| withhold packet 1 | `next-delete-abort-1.txt`, `read-after-abort-1.txt` | option `0x01`, acknowledge nothing, withhold packet 1's acknowledgement | 18 strokes, pages 36 and 37 |
| withhold packet 2 | `next-delete-abort-2.txt`, `read-after-abort-2.txt` | acknowledge packet 1, withhold packet 2's | 5 strokes, page 37 only |
| abort at packet 999 | `next-delete-abort-999.txt`, `read-after-full.txt` | option `0x01`, acknowledge every packet and answer the end packet with Stop, having asked for an abort that cannot happen | 0 strokes, no notes |

| Run | Packets received | Packets acknowledged | Strokes received | Strokes removed |
| --- | --- | --- | --- | --- |
| withhold packet 1 | 1 (13 strokes) | none | 13 | 0 |
| withhold packet 2 | 2 (13 + 5 strokes) | packet 1 | 18 | 13 |
| abort at packet 999 | 1 (5 strokes) | packet 1, carrying Stop | 5 | 5 |

Three things this measures rather than infers:

- **No acknowledgement removes nothing.** With packet 1 withheld, the pen still held all 18
  strokes, although it had already handed 13 of them over. So the pen does not delete a
  packet when it sends it.
- **Removal equals the acknowledged prefix.** The second run acknowledged packet 1, whose
  recorded size was 13 strokes, and the pen's inventory fell from 18 to 5: exactly what was
  acknowledged went, and the packet the pen had sent but not had acknowledged stayed. The
  removal is bounded by the acknowledgements down to the stroke.
- **Nothing unacknowledged went, not even the end packet.** Packet 2 was the transfer's last
  packet, so withholding its acknowledgement also withheld the Stop, and the pen kept its 5
  strokes. What the Stop contributes on its own is not separable from the acknowledgement
  that carries it; the subsection below records that.

The run also exercised the lab's refusal to report an abort it did not perform: with
`--abort-at-packet 999` the transfer reached its end packet and was acknowledged in full, so
the run failed with `the abort at packet 999 never happened: the transfer completed after 1
packet(s), so every packet was acknowledged and the pen removed everything it sent` and
exited 1. The read afterwards found the pen empty, which is what that message says happened.

The library was unaffected by the deletions and kept the new strokes: 8,438 strokes and
88,175 points before the runs, 8,456 and 88,332 after, with page 36 at 275 strokes and page
37 at 261. The 18 new strokes were split evenly, 9 on page 36 and 9 on page 37; the pen
removed page 36 entirely plus 4 of page 37's new strokes, and kept page 37's remaining 5.

### What triggered the removal is not settled

The runs show how much went, not which event removed it. A removal that waits for the
transfer to end is excluded: neither aborted run of the first experiment sent a Stop, and
both removed data anyway, and the re-run withheld the Stop itself and removed nothing of the
packet it belonged to. Two triggers remain indistinguishable, because the pen sends a packet
only after the previous acknowledgement, so in these runs the withheld acknowledgement is
also the last packet transmitted:

- the pen removes packet N once packet N is acknowledged, or
- the pen removes packet N once it sends packet N+1.

Both predict the same three outcomes, and the host may not be able to separate them: the
pen sends the next packet as soon as the previous one is acknowledged, so there is no
acknowledgement that leaves the following packet unsent. Telling them apart would take a
read taken while the link is still open, or an observer outside the host, and one BLE link
allows neither.

What a host can rely on holds under either trigger, and the re-run measured it rather than
assuming it: **the pen hands over a packet only after the previous one was acknowledged, so
removed data was acknowledged data** — no acknowledgement removed nothing, and one
acknowledgement removed exactly the strokes that packet carried. The design below depends on
that invariant rather than on the trigger, and nothing here should be read as proving which
trigger the firmware uses.

### What this means for deletion after a sync

The acknowledged `0x25` route is closed by `deletionScope`: it can only take a whole note,
so it cannot leave a page's newer strokes behind. The deleting transfer option is not a
narrower scope either — a completed transfer removed the whole note — but it puts the cut
somewhere else: removal is bounded by what the host has acknowledged, so the host decides
where that bound falls, packet by packet.

That is the ordering the cleanup rule asks for, without needing a page-scoped command or a
pen-reported revision to bound the window. A host that commits and flushes each packet
before acknowledging it would satisfy "deletion ordered after confirmed storage" with this
option, since the pen hands over a packet only after the previous acknowledgement, so it
can never remove data the host has not already stored. The re-run puts that on measurement
rather than on inference: withholding the first acknowledgement removed nothing, and
acknowledging one 13-stroke packet removed exactly those 13 strokes.

This is a design option that the change has since built on. Nothing here opens the
command gate: the four conditions in the section below describe the acknowledged
`0x25`/`0x27` path, and the *ordinary* read path still sends only `nextAndReserve`.
The deleting transfer is a separate, authorized route — streaming commits, an option
the read path may send only with a `PenDeletingReadAuthorization`, and evidence for
the transfer's own conditions instead of the delete command's — and the shipped build
takes it for the recorded identity, with a requested export, a per-sync confirmation,
and durable packet storage. Until that change, this run was a design option; it is now
the evidence the route's record is built from.

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

The four conditions describe this acknowledged path. The 2026-10-21 deleting transfer
option is a different route: it removes data while the transfer runs, so it has its own
record with its own conditions, and admitting it neither opens this gate nor settles a
condition here. See "Deleting transfer option, 2026-10-21" for what the option does, for
the record that route is built from, and for the verdicts it currently carries.

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
| Pen cleanup mode | That build requested no cleanup, so the pen kept its copy. No `0x25` or `0x27` deletion command is reachable: `PenCleanupPolicy.deletionEnabled` derives from the deletion evidence gate, whose recorded deletion-scope verdict is `unsafe`. The deleting transfer (`0x23` option `0x01`) is a separate route with its own record, and it was not part of this run |
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
| Pen cleanup mode | That build requested no cleanup, so the pen kept its copy. No `0x25` or `0x27` deletion command is reachable: `PenCleanupPolicy.deletionEnabled` derives from the deletion evidence gate, whose recorded deletion-scope verdict is `unsafe`. The deleting transfer (`0x23` option `0x01`) is a separate route with its own record, and it was not part of this run |

The per-scenario rows are recorded under "Save-and-export acceptance" in
`Tests/Hardware/README.md`. The byte counts match the files on disk, and the sanitized
transcript holds no Bluetooth address, serial number, or authentication material.
