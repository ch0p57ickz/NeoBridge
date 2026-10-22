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
and acknowledge every accepted packet with `0xA4`, using Continue until the end
packet and Stop for that packet. In a deleting transfer, it SHALL acknowledge a
packet only after that packet's complete strokes and recovery state are durably
committed and flushed. It SHALL send no acknowledgement for a rejected or
uncommitted packet.

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

#### Scenario: Deleting packet commit fails

- **WHEN** packet assembly, validation, durable storage, or its flush fails during a deleting transfer
- **THEN** the session sends no acknowledgement for that packet, stops the transfer, and reports the already committed packet prefix as partial progress, or fails the read naming the storage failure and marks the batch it opened failed when no packet was committed beforehand, because an empty prefix is not partial progress and an empty batch must not stay in progress

#### Scenario: Read ends before the first packet

- **WHEN** a deleting read ends before any packet is durably committed — the transport failed, the inbound stream ended, the pen refused or malformed a response, the first commit failed, or the read was cancelled while it waited for the first packet
- **THEN** the session fails the read, acknowledges nothing, and marks the batch it opened failed, so no deleting batch is left in progress with nothing in it

#### Scenario: Final packet commit precedes Stop

- **WHEN** a deleting transfer receives its end-position packet
- **THEN** the session sends Stop only after that packet and its recovery state are durable, and reports completion only after Stop is sent successfully

#### Scenario: Completion marker cannot be written

- **WHEN** every packet was committed and Stop was sent, but the durable completion marker cannot be written
- **THEN** the session reports the read as not durably complete while still recording that the transfer reached its last packet and naming the failure, so a storage fault is never reported as a transfer that stopped short

#### Scenario: Pen ends transfer while a packet commits

- **WHEN** durable storage of a received deleting packet takes long enough that the pen closes the transfer before its acknowledgement arrives
- **THEN** the session keeps the committed packet, reports an incomplete read and uncertain pen removal, and retries through a fresh read without claiming completion

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

### Requirement: Transfer option is evidence-backed and non-destructive

The session SHALL select the `0x23` transfer option from physical A1 trace
evidence. Ordinary and retention reads SHALL NOT send an option that deletes pen
data during transfer. They SHALL prefer an incremental option only when
known-stroke traces prove it returns every new stroke and leaves uncommitted
strokes retrievable after interruption. Otherwise they MAY use an established
non-destructive option; if none exists, they SHALL report offline retrieval as
unsupported.

#### Scenario: Transfer never deletes

- **WHEN** the session requests offline data for an ordinary or retention read
- **THEN** the transfer option it sends leaves the note's data on the pen regardless of the transfer's outcome

#### Scenario: Option comes from evidence

- **WHEN** the effect of an `OfflineTransferOption` value on the pen's cursor or stored data is not established by a trace
- **THEN** the session does not send that value

#### Scenario: Stored strokes are not re-sent

- **WHEN** a trace establishes an option that returns exactly the known new strokes, preserves old and new strokes after an interrupted read, and avoids re-sending old strokes
- **THEN** the session sends that option and the evidence record names the trace that establishes it

#### Scenario: No safe option is established

- **WHEN** no candidate option has evidence that it leaves uncommitted strokes retrievable
- **THEN** the session sends no `0x23` request and reports offline retrieval as unsupported

### Requirement: Deletion is ordered after confirmed storage

The session SHALL allow removal through a deleting transfer only for packets
durably committed before their `0xA4` acknowledgements. A separate deletion
command SHALL follow complete import, successful requested exports, and safe
command-specific trace verdicts for payload framing, deletion scope, response
meaning, and interrupted-transfer retention. A complete deleting transfer
includes the final end-position packet committed before Stop; a partial transfer
remains incomplete. The host SHALL state only the measured acknowledgement
bound, never an unproven internal removal trigger (`docs/protocol-a1.md:646-668`).

#### Scenario: Deletion follows a confirmed import

- **WHEN** a separate-command read has completed and been stored, every requested export has published, and the command evidence gate proves exactly that scope
- **THEN** the session sends the deletion command for that scope

#### Scenario: Failed import sends no deletion

- **WHEN** a transfer ends before its final packet, fails to store, or is canceled
- **THEN** the bytes sent through the transport contain no `0x25` or `0x27` command

#### Scenario: A later note fails

- **WHEN** an earlier note was completely imported and published but a later note fails
- **THEN** the overall sync remains incomplete; a separate command MAY delete only the earlier note's verified data if its proven scope excludes the failed note, while a deleting transfer MAY already have removed only its durably committed acknowledged prefix

#### Scenario: Deletion scope includes unverified data

- **WHEN** a command could also remove newer strokes or data from an incomplete note
- **THEN** the session sends no deletion command for that scope

#### Scenario: Deletion is requested once per stored transfer

- **WHEN** a stored transfer has already had its scoped deletion confirmed
- **THEN** the session sends no second deletion command for the same pages

#### Scenario: Packet was handed over but not acknowledged

- **WHEN** a deleting transfer stops after receiving a packet but before acknowledging it
- **THEN** the session reports that packet and the remainder as unconfirmed on the pen and does not claim the whole note was removed

#### Scenario: Removal trigger remains unknown

- **WHEN** a deleting transfer has acknowledged packets and a later read shows their strokes absent
- **THEN** the session SHALL report only the acknowledgement-bounded removed prefix, without claiming whether acknowledgement or sending the next packet caused removal

### Requirement: Deleting transfer requires explicit authorization

Only a cleanup read authorized for the current sync MAY send `0x23` option `0x01`,
and only when this sync requests an export, the version-matched deleting-transfer
evidence is safe, and durable packet storage is available. The ordinary read API
SHALL NOT expose the deleting option. Missing authorization or safety
preconditions SHALL prevent the deleting request.

#### Scenario: Explicit cleanup authorization

- **WHEN** cleanup is authorized for this sync — a saved deleting mode for an automatic sync, or an explicit choice for a directly driven read — the deleting-transfer evidence is safe, and durable packet storage is available before transfer
- **THEN** the cleanup read MAY send option `0x01` for a discovered note

#### Scenario: Cleanup authorization is absent

- **WHEN** authorization, evidence, or durable packet storage is absent
- **THEN** the session sends no deleting `0x23` request and reports why cleanup is unavailable

#### Scenario: No export request

- **WHEN** the sync requests no export
- **THEN** the session uses an ordinary non-destructive transfer and does not construct option `0x01`

### Requirement: Evidence-backed A1 pen state

When requested for a supported A1 session, the session SHALL send `0x04` after
the accepted version handshake and decode the `0x84` response before offline
discovery. It SHALL expose battery level, charging state, and percentage of pen
storage used. It SHALL reject a malformed or nonzero-error response and SHALL NOT
present guessed values.

#### Scenario: Pen reports its state

- **WHEN** an A1 responds to `0x04` with a valid 64-byte `0x84` payload
- **THEN** the result contains the decoded battery percentage, charging flag, and storage-used percentage

#### Scenario: Pen state is invalid

- **WHEN** the response is missing, rejected, truncated, or has an out-of-range percentage
- **THEN** the state query fails without presenting values as measured

#### Scenario: Existing portable caller does not request state

- **WHEN** a caller runs offline retrieval without enabling the state query
- **THEN** the session retains the established offline command sequence
