## Purpose

Defines portable protocol decoding and fixture behavior so captured pen traffic can be checked repeatably on Linux before device integration.

## ADDED Requirements

### Requirement: Transport-independent packet processing
The system SHALL accept byte input through a platform-neutral transport contract and report framed packets or explicit parse errors without requiring Apple frameworks. The initial A1 target SHALL be the Neo pen protocol 2.x family used by Neo's A1-capable SDKs; the supported minor-version range MUST be determined from the connected A1 and validated evidence, not inferred from an SDK release number. The parser MUST reject a decoded frame payload over 65,535 bytes or buffered undecoded input over 131,072 bytes with an explicit size-limit error and recover for the next frame.

#### Scenario: Valid fixture
- **WHEN** a supported sanitized fixture is replayed through a fake transport
- **THEN** the same ordered packet results are produced on repeated runs

#### Scenario: Malformed frame
- **WHEN** a fixture contains an invalid or truncated frame
- **THEN** parsing reports an explicit error and does not invent pen events

#### Scenario: Oversized input
- **WHEN** a frame payload or undecoded input exceeds its stated limit
- **THEN** parsing reports a size-limit error, discards that frame, and can parse a following valid frame

### Requirement: Version-aware evidence boundary
The system SHALL report the protocol version observed from the pen or fixture. A packet or command is **supported** only when its wire behavior is documented by an official Neo SDK or validated with a physical A1 and covered by a fixture test. A **provisional** mapping MAY be inspected in tests but MUST NOT authorize a production command or emit a completed domain stroke. An unknown command or unvalidated version MUST return an explicit unsupported result. Evidence MUST identify the SDK source or A1 model, firmware, observed protocol version, and capture date.

#### Scenario: Unsupported version
- **WHEN** fixture input declares an unsupported protocol version
- **THEN** the decoder returns an unsupported-version result instead of interpreting it as a supported packet

#### Scenario: Provisional command
- **WHEN** a fixture contains a command mapping without official SDK evidence or physical A1 validation
- **THEN** the decoder marks it provisional and does not emit a completed domain stroke or authorize a production request

### Requirement: Fixture privacy
Committed protocol fixtures MUST be sanitized to remove Bluetooth addresses, serial numbers, authentication material, and personally identifying handwriting content. Fixture metadata MUST record the sanitization performed and preserve the byte fields needed for the expected parse result.

#### Scenario: Fixture review
- **WHEN** a captured A1 trace is added to the test suite
- **THEN** review confirms the listed identifiers, secrets, and personal stroke content are absent and the expected decoded result remains reproducible

### Requirement: Portable fixture execution
The NeoCore and NeoProtocol test suites SHALL run with `swift test` on Linux using sanitized fixtures and without macOS frameworks, Xcode, Bluetooth hardware, or network services.

#### Scenario: Linux test run
- **WHEN** the portable test command runs on the supported Linux host
- **THEN** fixture and domain tests complete without Apple platform dependencies

### Requirement: A1 protocol spike gate
The project MUST document M0 protocol findings in `docs/protocol-a1.md` and demonstrate retrieval of a real offline stroke from a physical A1 before UI implementation begins. The evidence MUST record the A1 model, firmware, reported protocol version, capture date, observed request and response sequence, and a comparison between a known written test mark and the decoded page and stroke points. Offline retrieval MUST leave deletion disabled.

#### Scenario: Gate review
- **WHEN** UI implementation is proposed
- **THEN** the M0 evidence shows a decoded offline stroke on the expected page whose point sequence matches the known written test mark, with the recorded device/version details and no deletion request
