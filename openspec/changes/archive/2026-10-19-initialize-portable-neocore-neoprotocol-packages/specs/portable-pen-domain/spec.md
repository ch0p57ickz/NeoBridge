## Purpose

Defines portable pen data identity and replay behavior so live and offline inputs can be processed consistently across Linux and macOS.

## ADDED Requirements

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
