# Spec Delta

## Purpose

Keeps completed pen strokes in a durable local library, grouped by canonical Ncode page and safe to replay after interrupted reads.

## ADDED Requirements

### Requirement: Durable canonical pages
The system SHALL retain completed strokes across restarts under the full section, owner, book, and page identity.

#### Scenario: Same page number in different books
- **WHEN** two strokes have the same page number but different book or owner values
- **THEN** the library returns them from distinct pages after reopening

### Requirement: Replay-safe import
The system SHALL identify completed strokes by their canonical SHA-256 fingerprint and SHALL avoid duplicating a reliable stroke replayed from live or offline input. It SHALL preserve strokes whose identity is not reliable enough for cross-source deduplication.

#### Scenario: Repeated offline transfer
- **WHEN** a completed transfer is imported twice
- **THEN** the second import adds no duplicate reliable strokes

#### Scenario: Unreliable origin time
- **WHEN** a stroke has no reliable pen-origin start time
- **THEN** the system does not collapse it with a stroke from another source solely on the matching digest

### Requirement: Verified durable import
The system SHALL report storage success after a complete validated transfer commits. It SHALL report export success separately, only after every file for that transfer is published. A failed or interrupted transfer SHALL not be reported as saved.

#### Scenario: Transfer stops early
- **WHEN** a pen transfer ends before its final packet
- **THEN** the system reports failure and does not commit that incomplete transfer as a completed import

#### Scenario: Export publication fails
- **WHEN** strokes commit but a file export fails
- **THEN** the system reports that the library save succeeded and export failed, retains the strokes, and can retry publication without creating duplicate strokes

#### Scenario: Complete transfer contains no strokes
- **WHEN** a complete pen read contains no strokes
- **THEN** the system reports that no strokes were found and does not report exported files

### Requirement: Safe pen retention
The system SHALL retain the pen's copy in `keepOnPen` mode and SHALL NOT send pen deletion commands as part of import.

#### Scenario: Successful import
- **WHEN** a verified import and export complete
- **THEN** the pen's strokes remain on the pen and no deletion request is sent
