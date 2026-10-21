# Spec Delta

## MODIFIED Requirements

### Requirement: Offline retrieval and acknowledgement

The session SHALL request offline data with `0x23`, consume the `0xA3` info response, decode the incoming `0x24` packets through the transfer assembler, and acknowledge every accepted packet with `0xA4`, using Continue until the end packet and Stop for that packet. In a deleting transfer, it SHALL acknowledge a packet only after that packet's complete strokes and recovery state are durably committed and flushed. It SHALL send no acknowledgement for a rejected or uncommitted packet.

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

### Requirement: Transfer option is evidence-backed and non-destructive

The session SHALL select the `0x23` transfer option from physical A1 trace evidence. Ordinary and retention reads SHALL NOT send an option that deletes pen data during transfer. They SHALL prefer an incremental option only when known-stroke traces prove it returns every new stroke and leaves uncommitted strokes retrievable after interruption. Otherwise they MAY use an established non-destructive option; if none exists, they SHALL report offline retrieval as unsupported.

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

The session SHALL allow removal through a deleting transfer only for packets durably committed before their `0xA4` acknowledgements. A separate deletion command SHALL follow complete import, successful requested exports, and safe command-specific trace verdicts for payload framing, deletion scope, response meaning, and interrupted-transfer retention. A complete deleting transfer includes the final end-position packet committed before Stop; a partial transfer remains incomplete. The host SHALL state only the measured acknowledgement bound, never an unproven internal removal trigger (`docs/protocol-a1.md:646-668`).

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
- **THEN** the session sends no separate deletion command for that scope

#### Scenario: Deletion is requested once per stored transfer

- **WHEN** a stored transfer has already had its separately scoped deletion confirmed
- **THEN** the session sends no second deletion command for the same pages

#### Scenario: Packet was handed over but not acknowledged

- **WHEN** a deleting transfer stops after receiving a packet but before acknowledging it
- **THEN** the session reports that packet and the remainder as unconfirmed on the pen and does not claim the whole note was removed

#### Scenario: Removal trigger remains unknown

- **WHEN** a deleting transfer has acknowledged packets and a later read shows their strokes absent
- **THEN** the session SHALL report only the acknowledgement-bounded removed prefix, without claiming whether acknowledgement or sending the next packet caused removal

## ADDED Requirements

### Requirement: Deleting transfer requires explicit authorization

Only a cleanup read confirmed for the current sync MAY send `0x23` option `0x01`, and only when this sync requests an export, the version-matched deleting-transfer evidence is safe, and durable packet storage is available. The ordinary read API SHALL NOT expose the deleting option. Missing authorization or safety preconditions SHALL prevent the deleting request.

#### Scenario: Explicit cleanup authorization

- **WHEN** a user confirms cleanup for this sync, the deleting-transfer evidence is safe, and durable packet storage is available before transfer
- **THEN** the cleanup read MAY send option `0x01` for a discovered note

#### Scenario: Cleanup authorization is absent

- **WHEN** consent, evidence, or durable packet storage is absent
- **THEN** the session sends no deleting `0x23` request and reports why cleanup is unavailable

#### Scenario: No export request

- **WHEN** the sync requests no export
- **THEN** the session uses an ordinary non-destructive transfer and does not construct option `0x01`
