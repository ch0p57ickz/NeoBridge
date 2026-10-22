# portable-pen-domain Specification

## Purpose
Defines portable pen data identity and replay behavior so live and offline inputs can be processed consistently across Linux and macOS.

## Requirements

### Requirement: Canonical page identity
The system SHALL identify a page by the full Ncode tuple of section, owner, book, and page, preserving each component without lossy formatting.

#### Scenario: Distinct pages
- **WHEN** two page references differ in any tuple component
- **THEN** they resolve to distinct canonical page identities

### Requirement: Normalized stroke assembly
The system SHALL represent pen events and assembled strokes with page identity, pen-origin stroke time, ordered points, and source metadata independent of the transport platform. A point before a down event or a page change during an open stroke MUST produce an explicit invalid-sequence result and no completed stroke. A missing up event MUST retain an incomplete stroke and MUST NOT emit a completed stroke.

#### Scenario: Complete stroke
- **WHEN** a valid down, point sequence, and up event arrive for one page
- **THEN** the assembled stroke retains the event order and page identity

#### Scenario: Incomplete stroke
- **WHEN** a stroke ends without its required terminal event
- **THEN** the system retains an incomplete result and does not emit a completed stroke

#### Scenario: Invalid event order
- **WHEN** a point arrives before down or the page changes before up
- **THEN** the system reports an invalid sequence and emits no completed stroke

### Requirement: Replay-equivalent strokes share a fingerprint
The system SHALL derive a stable SHA-256 fingerprint from a versioned canonical representation of each completed stroke. Two strokes are replay-equivalent only when their full page tuple, pen-origin stroke start time, and ordered point sequence match after normalization to the same integer coordinate, pen-time, and pressure units.

#### Scenario: Changed stroke data
- **WHEN** a normalized point, pen-origin start time, or page identity changes
- **THEN** the canonical fingerprint changes

### Requirement: A fingerprint ignores transport and arrival facts
The fingerprint MUST exclude host arrival time, live/offline source, and transport chunking. It MUST preserve point order and MUST NOT round or omit normalized point values.

#### Scenario: Duplicate replay
- **WHEN** the same completed stroke is processed from live and offline input with matching pen-origin time and ordered normalized points
- **THEN** both inputs produce the same fingerprint for deduplication

### Requirement: A stroke without a pen-origin time is not deduplicated
A stroke without a reliable pen-origin start time MUST NOT be automatically deduplicated across sources.

#### Scenario: Missing pen time
- **WHEN** a completed stroke has no reliable pen-origin start time
- **THEN** the system preserves the stroke without automatic cross-source deduplication

### Requirement: Cleanup is the visible default when safe

The system SHALL treat cleanup as the default intent for each sync. A deleting
transfer SHALL require a standing saved mode for an automatic sync, or an
explicit authorization for a directly driven read, together with a requested
export, safe route evidence, and durable packet storage; otherwise the ordinary
non-destructive path SHALL retain pen data and explain why. Successful
publication SHALL NOT be a precondition to packet acknowledgement because
committed library data remains re-exportable.

#### Scenario: No choice means cleanup when safe

- **WHEN** a sync starts with no saved mode and no direct choice made
- **THEN** cleanup is shown as the intended default, but option `0x01` is not sent until an authorization exists and its safety preconditions pass

#### Scenario: A saved mode authorizes later syncs

- **WHEN** a deleting mode is saved and a later automatic sync runs
- **THEN** that sync may send option `0x01` without another confirmation, provided its safety preconditions pass

#### Scenario: Retention stays reachable

- **WHEN** the user chooses retention for a sync
- **THEN** that sync requests no deletion and the pen's strokes are retained

#### Scenario: Cleanup is unavailable

- **WHEN** the deleting-transfer evidence gate is closed or durable packet storage is unavailable before transfer
- **THEN** the pen's copy is retained and the user sees why cleanup was skipped

#### Scenario: Export fails after an acknowledged packet

- **WHEN** an acknowledged packet is durable but its requested file export later fails
- **THEN** the system reports the export failure and retains the packet's re-exportable library copy without claiming its pen copy remains

#### Scenario: No export requested

- **WHEN** the sync requests no file export
- **THEN** option `0x01` is unavailable, the ordinary non-destructive read retains the pen's copy, and the reason names the absent export request

### Requirement: A deletion request is journaled until the pen confirms it

For a separate deletion command, the system SHALL durably record the exact scope
before sending, mark it requested before bytes can reach the pen, and mark it
confirmed only when an evidence-backed response proves removal. An uncertain
command SHALL remain outstanding and SHALL NOT be resent automatically; it MAY be
resolved after a fresh read proves an unambiguous outcome for its recorded scope.
A deleting transfer SHALL instead record durable packet progress before
acknowledgement; it SHALL NOT use the command journal's
`prepared -> requested -> confirmed` states to imply confirmed removal.

#### Scenario: Interrupted between recording and sending

- **WHEN** the system records a separate deletion request and stops before the pen receives it
- **THEN** the request is reported as outstanding and the library's stored strokes remain available

#### Scenario: Pen confirms the request

- **WHEN** the pen returns a matching response whose meaning was physically verified as removal of the recorded scope
- **THEN** the request is recorded as confirmed for that scope

#### Scenario: No acknowledgement arrives

- **WHEN** a separate deletion command is sent and no acknowledgement arrives before its timeout
- **THEN** the request remains outstanding and the library's stored strokes remain available

#### Scenario: An unconfirmed request is not repeated blindly

- **WHEN** a separate deletion request is outstanding and a new sync begins
- **THEN** the system does not send a second deletion command for pages it has not confirmed

#### Scenario: Fresh read resolves an outstanding request

- **WHEN** a fresh read and the proven command scope show unambiguously whether a separate recorded deletion remains on the pen
- **THEN** the system records the observed outcome and avoids deleting newly written or unverified data

#### Scenario: Transfer acknowledgement has uncertain delivery

- **WHEN** packet storage commits but sending its acknowledgement fails or the connection drops
- **THEN** the system records the packet as durable with pen removal unknown, and a fresh read may replay it without a second deletion command

### Requirement: Deleting-transfer evidence is separate from command evidence

The single data-driven cleanup policy SHALL authorize each deletion route only
from that route's own safe verdicts. Transfer evidence SHALL apply only to
NWP-F151, firmware 3.00, protocol 2.23, and the observed uncompressed response;
any mismatch or unknown identity or shape closes it. The command record and its
unsafe `0x25` scope SHALL remain unchanged
(`Packages/NeoCore/Sources/NeoCore/PenCleanup.swift:140-169`).

#### Scenario: Each verdict is trace-backed

- **WHEN** the system evaluates the deleting-transfer evidence record
- **THEN** it assigns `safe` only when the cited physical observation establishes each condition; absent evidence is `pending` and contrary evidence is `unsafe`

| Verdict | What a trace must establish | 2026-10-21 observation |
| --- | --- | --- |
| Request and response framing | SDK option `0x01` forms the expected `0x23` request; `0xA3` accepts it with error `0x00`, `compressed=false`, and one `0x24` follows each `0xA4`. | `docs/protocol-a1.md:495-505,523-533,567-570` and the committed paired fixtures under `Tests/Fixtures/deleting-transfer/`, sanitized from the raw runs of 2026-10-21 (uncommitted, git-ignored). |
| Acknowledgement-bounded removal | Withholding packet 1's acknowledgement removes nothing; acknowledging a packet removes no more than its strokes and retains the sent but unacknowledged packet. | With 13 strokes handed over and no acknowledgement, all 18 remained; after acknowledging those 13, 5 remained (`docs/protocol-a1.md:608-629`; the committed fixtures under `Tests/Fixtures/deleting-transfer/`, sanitized from the 2026-10-21 re-run). |
| Response meaning | `0xA3` error `0x00` proves acceptance of the transfer request, not completed deletion; paired reads establish the resulting inventory. | Every run was accepted; each read-after measured remaining strokes (`docs/protocol-a1.md:530-535,608-629`). |
| Interrupted retention | Abandoning before acknowledgement retains that packet and later offline retrieval works without a power cycle. | Withheld packet 1 retained all 18; withheld packet 2 retained 5; normal reads followed both aborts (`docs/protocol-a1.md:584-586,608-633`). |

#### Scenario: Transfer evidence is safe

- **WHEN** every transfer verdict is safe for the connected firmware and packet durability is available
- **THEN** option `0x01` is eligible for an explicitly confirmed cleanup read

#### Scenario: Command gate remains closed

- **WHEN** the `0x25` command's deletion-scope verdict remains unsafe or the pen refuses `0x27`
- **THEN** neither command is authorized, regardless of the deleting-transfer verdicts

#### Scenario: Other firmware is not assumed safe

- **WHEN** the pen reports a different or unknown model, firmware, or protocol version, or unexpected compression or response shape
- **THEN** option `0x01` is unavailable pending compatible evidence
