# Spec Delta

## ADDED Requirements

### Requirement: Evidence-backed A1 pen state

When requested for a supported A1 session, the session SHALL send `0x04` after the accepted version handshake and decode the `0x84` response before offline discovery. It SHALL expose battery level, charging state, and percentage of pen storage used. It SHALL reject a malformed or nonzero-error response and SHALL NOT present guessed values.

#### Scenario: Pen reports its state

- **WHEN** an A1 responds to `0x04` with a valid 64-byte `0x84` payload
- **THEN** the result contains the decoded battery percentage, charging flag, and storage-used percentage

#### Scenario: Pen state is invalid

- **WHEN** the response is missing, rejected, truncated, or has an out-of-range percentage
- **THEN** the state query fails without presenting values as measured

#### Scenario: Existing portable caller does not request state

- **WHEN** a caller runs offline retrieval without enabling the state query
- **THEN** the session retains the established offline command sequence
