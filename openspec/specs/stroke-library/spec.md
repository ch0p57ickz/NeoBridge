# stroke-library Specification

## Purpose

Keeps completed pen strokes in a durable local library, grouped by canonical Ncode page and safe to replay after interrupted reads.

## Requirements

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

The system SHALL request cleanup by default when the evidence gate is open,
unless retention was chosen for the sync. It SHALL request deletion only for
data whose complete transfer has committed durably and for which an export
published in full. A sync that requested no export, or whose publication is
pending or failed, retains the pen's copy, which is then the read's only copy.
If any condition fails, it SHALL retain the pen's copy and report why cleanup
was skipped.

#### Scenario: Successful import

- **WHEN** a verified import and export complete
- **THEN** the pen's strokes remain on the pen and no deletion request is sent unless the evidence gate is open

#### Scenario: Successful import with retention

- **WHEN** a verified import and export complete and the user chose retention
- **THEN** the pen's strokes remain on the pen and no deletion request is sent

#### Scenario: Confirmed sync reclaims the pen's copy

- **WHEN** cleanup is intended, the transfer's import has committed, every requested export has published, and a physical trace proves deletion can target only that verified data
- **THEN** the system requests deletion for exactly that data

#### Scenario: Requested export did not publish

- **WHEN** a transfer's import has committed but an export that sync requested is pending or failed
- **THEN** the system sends no deletion request for that transfer

#### Scenario: Read requested no export

- **WHEN** a transfer's import has committed and the sync requested no export
- **THEN** the system sends no deletion request for that transfer and reports that no export published in full for it

#### Scenario: Evidence gate remains closed

- **WHEN** cleanup is intended but any required safety verdict is absent or unsafe
- **THEN** the system retains the pen's copy and reports that cleanup was skipped

#### Scenario: Stored copy survives deletion

- **WHEN** deletion is requested and the pen confirms it
- **THEN** the library copy of every deleted page remains readable and can be exported again

#### Scenario: Transfer stops early

- **WHEN** a pen transfer ends before its final packet
- **THEN** the pen's copy is retained and no deletion request is sent
