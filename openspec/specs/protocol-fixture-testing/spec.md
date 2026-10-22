# protocol-fixture-testing Specification

## Purpose
Defines portable protocol decoding and fixture behavior so captured pen traffic can be checked repeatably on Linux before device integration.

## Requirements

### Requirement: Transport-independent packet processing
The system SHALL accept byte input through a platform-neutral transport contract and report framed packets or explicit parse errors without requiring Apple frameworks.

#### Scenario: Valid fixture
- **WHEN** a supported sanitized fixture is replayed through a fake transport
- **THEN** the same ordered packet results are produced on repeated runs

#### Scenario: Malformed frame
- **WHEN** a fixture contains an invalid or truncated frame
- **THEN** parsing reports an explicit error and does not invent pen events

### Requirement: Oversized input is rejected with a size-limit error
The parser MUST reject a decoded frame payload over 65,535 bytes or buffered undecoded input over 131,072 bytes with an explicit size-limit error and recover for the next frame.

#### Scenario: Oversized input
- **WHEN** a frame payload or undecoded input exceeds its stated limit
- **THEN** parsing reports a size-limit error, discards that frame, and can parse a following valid frame

### Requirement: Supported version range comes from device evidence
The initial A1 target SHALL be the Neo pen protocol 2.x family used by Neo's A1-capable SDKs. The supported minor-version range MUST be determined from the connected A1 and validated evidence, not inferred from an SDK release number.

#### Scenario: Version range from device evidence
- **WHEN** a supported minor version is established from a connected A1 rather than from an SDK release number
- **THEN** the decoder accepts that version and reports the version it observed

#### Scenario: Version above the highest validated minor
- **WHEN** a fixture declares a minor version above the highest one that device evidence and SDK documentation validate
- **THEN** the version is not supported merely for being newer

### Requirement: Version-aware evidence boundary
A packet or command is **supported** only when its wire behavior is documented by an official Neo SDK or validated with a physical A1 and covered by a fixture test. A **provisional** mapping MAY be inspected in tests but MUST NOT authorize a production command or emit a completed domain stroke. Evidence MUST identify the SDK source or A1 model, firmware, observed protocol version, and capture date.

#### Scenario: Provisional command
- **WHEN** a fixture contains a command mapping without official SDK evidence or physical A1 validation
- **THEN** the decoder marks it provisional and does not emit a completed domain stroke or authorize a production request

### Requirement: Unknown commands and unvalidated versions are unsupported
An unknown command or unvalidated version MUST return an explicit unsupported result.

#### Scenario: Unsupported version
- **WHEN** fixture input declares an unsupported protocol version
- **THEN** the decoder returns an unsupported-version result instead of interpreting it as a supported packet

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

### Requirement: Response frames carry an error code

The packet body SHALL be `command, optional error code, length, payload`. A response
command SHALL carry an error code byte between the command and the length field; an event
or notification command SHALL NOT. The decoder MUST determine which layout a command uses
from the command identifier, and MUST report the error code together with the decoded
packet.

#### Scenario: Response frame with an error code

- **WHEN** a frame is replayed whose command identifier is a response and whose body carries an error code between the command and the length
- **THEN** the decoder reports a packet carrying that error code and the declared payload

#### Scenario: Event frame without an error code

- **WHEN** a frame is replayed whose command identifier is an event
- **THEN** the decoder reads the length immediately after the command and reports no error code

### Requirement: Offline data framing

The offline data command `0x24` (`REQ2_OFFLINE_DATA`), which the pen sends, MUST be framed
without an error code; its host-side acknowledgement `0xA4` (`RES2_OFFLINE_DATA`) is a
response and carries one.

#### Scenario: Offline data framing

- **WHEN** a frame carries the offline data identifier `0x24` from the pen
- **THEN** the decoder reads the length immediately after the command and recovers the declared payload

### Requirement: A non-zero error code fails the command

A response whose error code is non-zero MUST produce an explicit protocol error and MUST
NOT be decoded as a payload.

#### Scenario: Failed response

- **WHEN** a response frame carries a non-zero error code
- **THEN** the layer that turns frames into device tokens reports an explicit failure for that command and produces no events for that frame, while the framing layer still reports the packet with its error code so the failed exchange stays diagnosable

### Requirement: An unclassified command is rejected

The decoder MUST NOT guess a body layout for a command identifier that the evidence table
does not classify as a response or an event.

#### Scenario: Unknown command

- **WHEN** a frame carries a command identifier that the evidence table does not classify as a response or an event
- **THEN** the decoder reports an unknown-command error rather than guessing a body layout

### Requirement: Pen-reported compression capability

The system SHALL determine whether the pen supports compressed offline transfer from the
capability byte the pen reports in its version response, and MUST NOT infer that support
from the protocol version alone. A version response MUST be parsed with the payload layout
the official SDK documents: device name, firmware version, protocol version text,
sub-name, device type, Bluetooth address, pressure sensor type, and then the compression
capability byte.

#### Scenario: Compression capability reported as clear

- **WHEN** a pen reports a protocol version at or above the compression-capable minor but its capability byte is clear
- **THEN** the system reports compressed transfer as unsupported for that pen

#### Scenario: Compression capability reported as set

- **WHEN** the capability byte is non-zero and the reported protocol version is at or above the compression-capable minor
- **THEN** the system reports compressed transfer as supported

#### Scenario: Capability byte absent

- **WHEN** a version payload is shorter than the layout needed to reach the capability byte
- **THEN** the system reports compressed transfer as unsupported without failing the whole response

### Requirement: Offline transfers assemble from their packets

The system SHALL assemble an offline data transfer from the packets the pen sends, and
MUST report whether the transfer is complete. The pen sends one packet per host
acknowledgement, and each packet carries an identifier and a transfer position of start,
middle, or end. A packet MUST be decoded on its own terms, because a packet is one slice
of a transfer rather than a whole one.

#### Scenario: Complete transfer

- **WHEN** a transfer is assembled from its start packet through its end packet
- **THEN** the assembled stream holds every packet's strokes and the transfer reports complete

### Requirement: A transfer is complete only on its end packet

The system MUST NOT treat a transfer as complete before its end packet arrives. An
ordinary incomplete transfer is not importable as a completed read. A deleting
transfer MAY retain a validated, durably committed packet prefix as partial library
data before the end packet, but MUST NOT report that prefix as a completed transfer.

#### Scenario: Packet before the end

- **WHEN** only start and middle packets have arrived
- **THEN** the transfer reports incomplete; an ordinary read is not importable as complete, and a deleting read exposes only its durable partial prefix

#### Scenario: Packet after the end

- **WHEN** a packet arrives after the transfer has already reported complete
- **THEN** the system reports an explicit error

### Requirement: Deleting transfer evidence and failure replay

Portable fixtures SHALL pair each deleting transcript with its read-after transcript,
comparing stroke identities and inventory to establish retention or removal. They
SHALL verify option `0x01` framing, accepted `0xA3`, and one `0x24` per `0xA4`.
Fake-transport tests SHALL exercise commit-before-acknowledgement, interruption, and
replay. The physical claim is bounded by `docs/protocol-a1.md:608-629,646-668`; the
trigger remains unclassified.

#### Scenario: Physical pair without acknowledgement

- **WHEN** a deleting transfer's first packet is received but not acknowledged
- **THEN** its paired read-after fixture returns all 18 starting stroke identities, including the 13 handed over by that packet

#### Scenario: Storage failure prevents acknowledgement

- **WHEN** a fake session cannot durably commit its first deleting packet
- **THEN** it sends no `0xA4` for that packet and reports no completed read

#### Scenario: One acknowledged packet

- **WHEN** the deleting transcript acknowledges its 13-stroke first packet and withholds the second packet's acknowledgement
- **THEN** the paired read-after fixture returns the second packet's 5 strokes and none of the first packet's 13, while the fake session proves commit preceded the first acknowledgement

#### Scenario: Crash and replay

- **WHEN** the fake session stops after durable commit before or after acknowledgement and a new read returns overlapping strokes
- **THEN** the library retains all committed strokes and replay does not duplicate reliable strokes

#### Scenario: Closed command gate

- **WHEN** the transfer-option evidence is safe but the command-specific deletion-scope verdict remains unsafe
- **THEN** tests show neither `0x25` nor `0x27` can be encoded or sent by the app path

#### Scenario: Unsupported variant

- **WHEN** a pen version or response shape is outside the validated deleting-transfer evidence
- **THEN** the fake session sends no deleting option and reports it as unsupported

#### Scenario: Sanitized fixture is self-contained

- **WHEN** portable tests run without the git-ignored raw capture directories
- **THEN** committed sanitized fixtures still prove request framing, packet counts, and acknowledgement order without Bluetooth addresses, serial numbers, or authentication material

#### Scenario: Pen abandons while the host commits

- **WHEN** a paced fake pen closes the transfer before a slow durable packet commit finishes
- **THEN** the committed packet remains available, no completed transfer is reported, and a fresh read recovers the remainder without losing acknowledged data

### Requirement: An identifier gap is reported, not imported

The system MUST report a packet that does not continue the identifier sequence instead of
importing a hole.

#### Scenario: Dropped packet

- **WHEN** a packet arrives whose identifier does not continue the sequence
- **THEN** the system reports an explicit error and does not count that packet

### Requirement: A resumed transfer may begin mid-stream

A start packet MUST NOT be required, so a transfer that resumes mid-stream after a
reconnect is accepted.

#### Scenario: Resumed transfer

- **WHEN** assembly begins at a packet whose position is middle
- **THEN** the packet is accepted and the transfer completes when its end packet arrives
