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

The system SHALL intend cleanup for each sync by default and SHALL show that
intent before transfer. A user MAY choose retention for that sync. Cleanup SHALL
run only when the evidence gate and verified import and export conditions pass;
otherwise the system SHALL retain pen data and report the reason. A retention
choice SHALL NOT carry into a later sync without a new choice.

#### Scenario: No choice means cleanup when safe

- **WHEN** a sync runs without a cleanup choice being made
- **THEN** cleanup is intended, and deletion is requested only after all safety conditions pass

#### Scenario: A choice does not persist silently

- **WHEN** a sync ran in retaining mode and a later sync runs
- **THEN** the later sync presents default cleanup before its transfers are stored

#### Scenario: Retention stays reachable

- **WHEN** the user chooses retention for a sync
- **THEN** that sync requests no deletion and the pen's strokes are retained

#### Scenario: Cleanup is unavailable

- **WHEN** the evidence gate is closed or a requested export fails
- **THEN** the pen's copy is retained and the user sees why cleanup was skipped

### Requirement: A deletion request is journaled until the pen confirms it

The system SHALL durably record the exact deletion scope before sending it,
mark it requested before bytes can reach the pen, and mark it confirmed only
when an evidence-backed matching pen response proves removal of that scope.
A request whose effect is unknown SHALL remain outstanding. The system SHALL
NOT resend it automatically; it MAY resolve it after a fresh read proves an
unambiguous outcome for the recorded scope.

#### Scenario: Interrupted between recording and sending

- **WHEN** the system records a deletion request and stops before the pen receives it
- **THEN** the request is reported as outstanding and the library's stored strokes remain available

#### Scenario: Pen confirms the request

- **WHEN** the pen returns a matching response whose meaning was physically verified as removal of the recorded scope
- **THEN** the request is recorded as confirmed for that scope

#### Scenario: No acknowledgement arrives

- **WHEN** a deletion command is sent and no acknowledgement arrives before its timeout
- **THEN** the request remains outstanding and the library's stored strokes remain available

#### Scenario: An unconfirmed request is not repeated blindly

- **WHEN** a request is outstanding and a new sync begins
- **THEN** the system does not send a second deletion command for pages it has not confirmed

#### Scenario: Fresh read resolves an outstanding request

- **WHEN** a fresh read and the proven command scope show unambiguously whether the recorded data remains on the pen
- **THEN** the system records the observed outcome and avoids deleting any newly written or unverified data
