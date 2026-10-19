# M0 A1 protocol spike

This document is the gate for UI implementation. NeoBridge does not start UI work
until the offline retrieval trace below is completed on a physical A1 and
reviewed.

Status: **incomplete — the physical A1 capture has not been performed.** Every
hardware-dependent row is marked `pending`.

## Device record

| Field | Value |
| --- | --- |
| Pen model | A1 (F151) |
| Pen firmware | pending |
| Reported protocol version | pending (fixture and SDK evidence use `2.18`) |
| Capture date | pending |
| Capture host | pending (macOS runner or Linux host with a BLE adapter) |
| App version | pending |

The A1 is listed as a supported device by Neo's official iOS SDK 3.0, and that
SDK declares protocol version `2.18` in its `VERSION_INFO` request. This
establishes the protocol family. It does not establish the firmware version of
the pen under test, which is why the rows above stay pending until capture.

## Protocol facts established from official SDK wire evidence

Source: Neo iOS SDK 3.0, commit `a53a01e`
(`https://github.com/NeoSmartpen/iOS-SDK3.0`).

### Framing

| Fact | Value | Source |
| --- | --- | --- |
| Start-of-frame marker | `0xC0` | `NISDK3/Classes/Common/Global.swift` |
| End-of-frame marker | `0xC1` | `NISDK3/Classes/Common/Global.swift` |
| Byte-stuffing escape | `0x7D`, then the byte XOR `0x20` | `NISDK3/Classes/Util/FunctionUtil.swift` (`makeWholePacket`) |
| Frame body | command (1 byte), length (UInt16 little-endian), payload | `NISDK3/Classes/PenController/PenCommParser.swift` |
| Integers | Little-endian | `NISDK3/Classes/Util/FunctionUtil.swift` |

### Command identifiers

The full command table is in `NISDK3/Classes/Model/CMD.swift` and is mirrored by
`PenCommand` in `Packages/NeoProtocol`.

### Page identity

`PageInfo` (`0x64`, `0x6B`) carries owner (24 bits), section (1 byte), book
(4 bytes), and page (4 bytes). `0x6B` payloads carry a leading event count.

### Dot payload

`Dot` (`0x65`, `0x6C`) carries a time delta in milliseconds, raw pressure,
x and y as a 16-bit integer part plus a two-digit fractional part, tilt, and
twist. Offline dots (`0xA4` stroke data) append two reserved bytes and a checksum
that is the sum of the preceding bytes truncated to one byte.

### Offline data packet

`OffLineData` (`0xA4`) carries an 18-byte header (packet id, compression flag,
sizes, transfer position, owner, section, book, stroke count) followed by 27-byte
stroke records, each followed by its 16-byte offline dots. The transfer position
values come from the SDK's `OfflineTransPosition`: 0 start, 1 middle, 2 end.

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

## Offline retrieval trace (to run on hardware)

Perform these steps with the pen connected, then record the raw exchange with
sensitive fields removed.

1. Record the model and firmware from `RES_VERSION_INFO` (`0x81`).
2. Write a known test mark on a page whose Ncode tuple is recorded by hand.
3. Disconnect, then reconnect and request the offline note list (`0x21`), page
   list (`0x22`), and offline data (`0x23`, `0x24`).
4. Capture the `0xA4` responses and decode them with
   `OfflineDataParser.parse(payload:)`.
5. Compare the decoded page tuple and the ordered point sequence against the
   known test mark.
6. Confirm that no deletion request (`0x25`, `0x27`) was sent.

### Result

| Check | Result |
| --- | --- |
| Decoded page matches the page written on | pending |
| Point sequence matches the known mark | pending |
| No deletion request sent | pending |
| Pen cleanup mode | `keepOnPen` (enforced by `PenCleanupPolicy.deletionEnabled == false`) |
| Evidence reviewed by | pending |

## Fixture coverage today

`Tests/Fixtures` holds six sanitized fixtures with recorded provenance,
sanitization, device model, observed protocol version, and expected output:

| Fixture | Covers |
| --- | --- |
| `a1-version-info-2.18` | version handshake, zeroed Bluetooth address |
| `a1-realtime-stroke` | live down, four dots, up |
| `a1-offline-stroke` | offline data packet with checksummed dots |
| `a1-truncated-frame` | truncated frame and recovery |
| `a1-size-limit-recovery` | payload and buffer limits and recovery |
| `a1-escaped-page-identity` | byte-stuffing round trip |

These fixtures are synthetic reconstructions of the documented wire layout, not
recordings of the user's pen. Replace or extend them with sanitized captures from
the trace above.

## Gate

UI implementation may begin only when:

- the device record and offline retrieval trace above are complete,
- the decoded page and point sequence match the known test mark,
- no deletion request was sent,
- and the evidence has been reviewed.
