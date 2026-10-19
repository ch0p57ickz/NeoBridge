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
| Offline deletion | `0x25`, `0x27` | official SDK | blocked until A1 acceptance |
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
| Pen cleanup mode | `keepOnPen` (enforced by `PenCleanupPolicy.deletionEnabled == false`) |
| Evidence reviewed by | Jimmy, 2026-10-18 |

## Fixture coverage today

`Tests/Fixtures` holds eight sanitized fixtures with recorded provenance,
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

Seven of these are synthetic reconstructions of the documented wire layout, built by
`Tests/Fixtures/generate-fixtures.py`. The eighth, `a1-handshake-version-2.23`, is
derived from the recorded handshake above, with the Bluetooth address field zeroed; it
carries no serial number and no stroke content. The full capture is not committed,
because its stroke coordinates are the user's own handwriting. Raw captures belong in
`Tests/Fixtures/raw/`, which is git-ignored.

## Gate

UI implementation may begin only when:

- the device record and offline retrieval trace above are complete — **done**,
- the decoded page and point sequence match the known test mark — **done**,
- no deletion request was sent — **done**,
- and the evidence has been reviewed — **done**, by the pen owner on 2026-10-18.

All four conditions hold, so the gate is open and UI implementation may begin.

The evidence still requires codec corrections, which are tracked separately in
`openspec/changes/correct-a1-codec-from-hardware-evidence/`:

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
