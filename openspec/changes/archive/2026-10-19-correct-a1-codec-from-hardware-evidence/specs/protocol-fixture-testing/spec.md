## ADDED Requirements

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

The system MUST NOT treat a transfer as complete before its end packet arrives.

#### Scenario: Packet before the end

- **WHEN** only start and middle packets have arrived
- **THEN** the transfer reports incomplete and is not importable

#### Scenario: Packet after the end

- **WHEN** a packet arrives after the transfer has already reported complete
- **THEN** the system reports an explicit error

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
