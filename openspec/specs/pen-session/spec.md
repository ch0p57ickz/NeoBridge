# pen-session Specification

## Purpose

Defines the portable connection and synchronization lifecycle that drives a pen
through version verification and offline retrieval over the platform-neutral
`PenTransport` contract, so the same behavior is testable with a fake
transport and reusable by any host.

## Requirements

### Requirement: Transport-neutral session

The session SHALL exchange bytes only through the `PenTransport` contract and
SHALL NOT depend on any Bluetooth or UI framework, so it can run against a fake
transport in tests.

#### Scenario: Session runs on a fake transport

- **WHEN** a session is created with an in-memory fake transport
- **THEN** it completes its lifecycle without any platform Bluetooth API

### Requirement: Version gate before retrieval

After the connection is established, the session SHALL complete the version
handshake and SHALL begin offline retrieval only when the pen's reported
protocol version is supported by the validated-minor policy.

#### Scenario: Supported version proceeds

- **WHEN** the pen reports a validated protocol minor
- **THEN** the session proceeds to offline note discovery

#### Scenario: Unvalidated version is refused

- **WHEN** the pen reports a minor outside the validated set
- **THEN** the session reports the version as unsupported and sends no offline-data request

#### Scenario: Default connection code is rejected

- **WHEN** the pen rejects the observed `0x01` handshake using the SDK default code
- **THEN** the session reports that the pen is unsupported or protected and does not guess another code

### Requirement: Establish the offline discovery input

The session SHALL use an evidence-backed initial `sectionOwnerId` or documented
wildcard for `0x21`. It SHALL NOT guess this value.

#### Scenario: Initial section and owner are not established

- **WHEN** the session has no evidence-backed `sectionOwnerId` or documented wildcard for `0x21`
- **THEN** it sends no offline-list request and reports that discovery is unsupported

### Requirement: Discover requestable offline notes

After version verification, the session SHALL decode the `0xA1` note list,
request a corresponding `0xA2` page list with `0x22`, and use discovered IDs
in each `0x23` request. List decoding SHALL be verified by sanitized
evidence-backed fixtures before production use. Malformed or unsupported list
data SHALL stop retrieval before `0x23`.

#### Scenario: Discovered note is retrieved

- **WHEN** the pen reports a requestable note and page list
- **THEN** the session requests offline data for that discovered note with a zero page count

#### Scenario: No offline notes

- **WHEN** the pen reports an empty note list
- **THEN** the session completes with zero counts and sends no `0x23` request

#### Scenario: List data cannot be decoded

- **WHEN** a note or page list response is malformed or unsupported
- **THEN** the session fails without sending `0x23`

#### Scenario: Several notes are present

- **WHEN** the pen reports more than one note
- **THEN** the session uses a separate transfer assembler for each note and reports completion only after every note has completed

### Requirement: Complete all discovered notes

The session SHALL complete every discovered note or report an incomplete sync.
It SHALL NOT present unprocessed notes as a completed pen sync.

#### Scenario: A later note fails

- **WHEN** an earlier note completes but a later discovered note fails
- **THEN** the overall sync fails and preserves the completed note count only as diagnostic progress

### Requirement: Offline retrieval and acknowledgement

The session SHALL request offline data with `0x23`, consume the `0xA3` info
response, decode the incoming `0x24` packets through the transfer assembler,
and acknowledge every packet with `0xA4`, using Continue until the end packet
and Stop for that packet.

#### Scenario: Multi-packet transfer completes

- **WHEN** the pen streams a transfer that ends with an end-position packet
- **THEN** the session acknowledges the final packet with Stop and reports the assembled transfer as complete

#### Scenario: Acknowledgement controls pacing

- **WHEN** the pen waits for an acknowledgement before sending the next packet
- **THEN** the session sends one `0xA4` Continue for each non-final packet and `0xA4` Stop for the end packet before reporting completion

#### Scenario: Interrupted stream

- **WHEN** the transport ends before an end-position packet arrives
- **THEN** the session reports an incomplete transfer and does not report completion

#### Scenario: Pen rejects a request

- **WHEN** a response carries a nonzero protocol error code
- **THEN** the session fails without treating the response payload as data

### Requirement: Counts come from decoded packets

The session SHALL count strokes and dots from accepted `0x24` packets and
distinct pages from their canonical page identities. It SHALL NOT use `0xA3`
summary counts as the final result because the physical A1 trace showed that
the summary lagged the packet stream.

#### Scenario: Summary differs from transfer

- **WHEN** `0xA3` reports fewer strokes than the completed `0x24` transfer
- **THEN** the completed result uses the decoded transfer counts

### Requirement: Bounded waits and fresh retry

The session SHALL bound waits for protocol responses and packets. Cancellation,
timeout, interruption, malformed data, packet gaps, and unsupported compressed
data SHALL prevent a completed result. A retry SHALL create fresh decoder and
assembler state and close the prior transport.

#### Scenario: Pen stops responding

- **WHEN** a required response or next packet does not arrive before its timeout
- **THEN** the session fails with a descriptive error and closes the transport

#### Scenario: Retry after partial transfer

- **WHEN** a partial transfer fails and the user retries
- **THEN** the new session starts with no buffered frame or partial transfer from the failed session

### Requirement: Destructive commands remain disabled

The session SHALL NOT send the pen deletion commands `0x25` or `0x27` while
cleanup remains in `keepOnPen` mode.

#### Scenario: Completed sync sends no deletion

- **WHEN** a sync completes successfully
- **THEN** the bytes sent through the transport contain no `0x25` or `0x27` command

### Requirement: Session lifecycle state

The session SHALL expose one lifecycle state at a time — idle, connecting,
verifying, syncing, complete, or failed — and SHALL enter `failed` with a
descriptive error when a step fails.

#### Scenario: State follows progress

- **WHEN** a session connects, verifies, and syncs
- **THEN** it reports each state in that order before reporting `complete`

#### Scenario: Failure is recoverable

- **WHEN** a step fails and the session enters `failed`
- **THEN** a new session can begin without restarting the host application
