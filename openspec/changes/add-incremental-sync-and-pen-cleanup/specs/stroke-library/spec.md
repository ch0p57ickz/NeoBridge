# Spec Delta

## MODIFIED Requirements

### Requirement: Safe pen retention

The system SHALL request cleanup by default when the evidence gate is open,
unless retention was chosen for the sync. It SHALL request deletion only for
data whose complete transfer has committed durably and whose every requested
export has published successfully. If any condition fails, it SHALL retain the
pen's copy and report why cleanup was skipped.

#### Scenario: Successful import with retention

- **WHEN** a verified import and export complete and the user chose retention
- **THEN** the pen's strokes remain on the pen and no deletion request is sent

#### Scenario: Confirmed sync reclaims the pen's copy

- **WHEN** cleanup is intended, the transfer's import has committed, every requested export has published, and a physical trace proves deletion can target only that verified data
- **THEN** the system requests deletion for exactly that data

#### Scenario: Requested export did not publish

- **WHEN** a transfer's import has committed but an export that sync requested is pending or failed
- **THEN** the system sends no deletion request for that transfer

#### Scenario: Evidence gate remains closed

- **WHEN** cleanup is intended but any required safety verdict is absent or unsafe
- **THEN** the system retains the pen's copy and reports that cleanup was skipped

#### Scenario: Stored copy survives deletion

- **WHEN** deletion is requested and the pen confirms it
- **THEN** the library copy of every deleted page remains readable and can be exported again

#### Scenario: Transfer stops early

- **WHEN** a pen transfer ends before its final packet
- **THEN** the pen's copy is retained and no deletion request is sent
