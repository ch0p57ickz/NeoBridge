# Spec Delta

## MODIFIED Requirements

### Requirement: A transfer is complete only on its end packet

The system MUST NOT treat a transfer as complete before its end packet arrives. An ordinary incomplete transfer is not importable as a completed read. A deleting transfer MAY retain a validated, durably committed packet prefix as partial library data before the end packet, but MUST NOT report that prefix as a completed transfer.

#### Scenario: Packet before the end

- **WHEN** only start and middle packets have arrived
- **THEN** the transfer reports incomplete; an ordinary read is not importable as complete, and a deleting read exposes only its durable partial prefix

#### Scenario: Packet after the end

- **WHEN** a packet arrives after the transfer has already reported complete
- **THEN** the system reports an explicit error

## ADDED Requirements

### Requirement: Deleting transfer evidence and failure replay

Portable fixtures SHALL pair each deleting transcript with its read-after transcript, comparing stroke identities and inventory to establish retention or removal. They SHALL verify option `0x01` framing, accepted `0xA3`, and one `0x24` per `0xA4`. Fake-transport tests SHALL exercise commit-before-acknowledgement, interruption, and replay. The physical claim is bounded by `docs/protocol-a1.md:608-629,646-668`; the trigger remains unclassified.

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
