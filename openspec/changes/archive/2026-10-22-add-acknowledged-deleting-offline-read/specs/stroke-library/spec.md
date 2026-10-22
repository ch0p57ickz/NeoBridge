# Spec Delta

## MODIFIED Requirements

### Requirement: Verified durable import

The system SHALL report storage success after a complete validated ordinary transfer commits. A failed or interrupted ordinary transfer SHALL NOT be reported as saved. For a deleting transfer, it SHALL commit each validated packet's complete strokes and recovery state durably before acknowledgement, even if transfer later fails, and SHALL label that progress partial rather than a saved completed read. Export success remains separate and requires every requested file to publish (`openspec/specs/stroke-library/spec.md:27-40`).

#### Scenario: Transfer stops early

- **WHEN** an ordinary pen transfer ends before its final packet
- **THEN** the system reports failure and does not commit that incomplete transfer as a completed import

#### Scenario: Export publication fails

- **WHEN** strokes commit but a file export fails
- **THEN** the system reports that the library save succeeded and export failed, retains the strokes, and can retry publication without creating duplicate reliable strokes

#### Scenario: Complete transfer contains no strokes

- **WHEN** a complete pen read contains no strokes
- **THEN** the system reports that no strokes were found and does not report exported files

#### Scenario: Deleting transfer stops after an acknowledged prefix

- **WHEN** a deleting transfer fails after some packets have been acknowledged
- **THEN** every acknowledged packet's strokes remain durable and readable, the batch is marked partial, and neither the note nor the sync is reported complete

#### Scenario: Crash after commit before acknowledgement

- **WHEN** a packet commit succeeds but its acknowledgement is not confirmed sent
- **THEN** recovery retains the packet as durable, treats its pen copy as uncertain, and accepts a fresh replay without duplicating reliable strokes

### Requirement: Safe pen retention

The system SHALL use a non-destructive transfer for retention, a read with no requested export, or when deleting-transfer conditions are unavailable. For an explicitly confirmed deleting transfer with a requested export, it SHALL permit packet removal only after a durable packet commit, even if publication has not yet succeeded. It SHALL preserve the library copy for publication retry. The separate `0x25`/`0x27` command path SHALL retain its complete-import, successful-publication, and command-evidence preconditions.

#### Scenario: Successful import

- **WHEN** a verified non-destructive import and export complete
- **THEN** the pen's strokes remain on the pen and no separate deletion request is sent unless the command evidence gate is open

#### Scenario: Successful import with retention

- **WHEN** a verified import and export complete and the user chose retention
- **THEN** the pen's strokes remain on the pen and no deletion request is sent

#### Scenario: Confirmed sync reclaims the pen's copy

- **WHEN** cleanup is confirmed and each deleting-transfer packet has committed durably before its acknowledgement
- **THEN** the pen MAY remove the acknowledged packet prefix while the library retains those strokes for later export

#### Scenario: Requested export did not publish

- **WHEN** a deleting transfer's packets committed but a requested export is pending or failed
- **THEN** the system retains the library copy, reports export incomplete, and offers publication retry without promising the pen still holds acknowledged packets

#### Scenario: Read requested no export

- **WHEN** a sync requests no export
- **THEN** the system uses the ordinary non-destructive transfer, sends no option `0x01`, and reports that cleanup is unavailable because no export was requested

#### Scenario: Evidence gate remains closed

- **WHEN** cleanup is intended but any required deleting-transfer safety verdict is absent or unsafe
- **THEN** the system sends no option `0x01` and reports cleanup unavailable

#### Scenario: Stored copy survives deletion

- **WHEN** a deleting packet has been acknowledged and the pen later omits it from a fresh read
- **THEN** the library copy of its strokes remains readable and can be exported again

#### Scenario: Transfer stops early

- **WHEN** a deleting transfer ends before its final packet
- **THEN** committed packets remain in the library, the batch is partial, and no separate deletion command is sent

## ADDED Requirements

### Requirement: Partial deleting batches remain recoverable

The system SHALL durably associate deleting packet commits with sync, note, packet progress, and canonical pages. It SHALL store transfer kind and completion (`inProgress`, `partial`, `complete`) independently of publication, preserving `partial + published` across restarts. Committed pages SHALL remain exportable; an acknowledgement send SHALL NOT imply confirmed pen removal (`Packages/NeoCore/Sources/NeoCore/PenDomainInterfaces.swift:13-43`; `PenImportContracts.swift:164-200`).

#### Scenario: Restart after partial transfer

- **WHEN** the app restarts after one or more deleting packets were committed and the read stopped
- **THEN** the library still holds the partial batch and its committed pages, those pages can be published again, and a fresh read can complete the remaining pen data

#### Scenario: Packet contains incomplete stroke data

- **WHEN** a packet cannot produce complete validated strokes and durable recovery data
- **THEN** it is not acknowledged and no uncommitted stroke is represented as saved

#### Scenario: Later note fails

- **WHEN** one note finishes and a later note fails during a deleting sync
- **THEN** committed data from both notes remains available, each note's completion is recorded separately, and the overall sync is partial

### Requirement: A read that ends before its first packet fails its batch

A deleting read SHALL NOT leave its batch in progress with no durable packet. The batch it opened SHALL be marked failed, SHALL keep its row for the journal and a later diagnosis, and SHALL NOT be publishable, because publication requires a durable packet. A batch that is not an empty, in-progress deleting batch SHALL be left unchanged.

#### Scenario: Read ends before the first packet

- **WHEN** a deleting read ends before any packet is durably committed, whether the transport failed, the inbound stream ended, the pen refused or malformed a response, the first commit failed, or the read was cancelled while it waited for the first packet
- **THEN** the batch it opened is marked `failed` with completion `partial`, its row is kept rather than removed, and it can never publish

#### Scenario: Another batch is left unchanged

- **WHEN** the marking is applied to an ordinary batch, a deleting batch with a durable packet, a finished batch, or an identifier no batch holds
- **THEN** every one of those rows keeps the state and completion it already had

### Requirement: Partial publication does not complete a deleting read

A deleting batch SHALL be publication-retryable after its first durable packet. Successful publication SHALL set `published` without changing completion. A fresh read of the remainder SHALL start a new batch, leaving the old batch partial. A deleting batch SHALL never qualify for a separate deletion command. A published incomplete batch SHALL still block a shared page from separate command deletion.

#### Scenario: Partial batch publishes

- **WHEN** a partial deleting batch's committed pages publish successfully
- **THEN** the batch is both `partial` and `published` after restart; it is not shown as a complete pen read

#### Scenario: Partial batch retries publication

- **WHEN** publication of a partial deleting batch fails and the user retries
- **THEN** `publish` and `retryExport` render its durable pages, report per-file outcomes, and retain `partial` until a separate fresh read stores the remainder in a new batch

#### Scenario: Separate cleanup refuses deleting batch

- **WHEN** `requestCleanup` receives a deleting batch, including one marked `published` and `complete`
- **THEN** it sends no `0x25` or `0x27` and returns a reason identifying transfer cleanup as already selected

#### Scenario: Published partial batch blocks command scope

- **WHEN** an ordinary batch's candidate command-deletion scope shares a page with a published but incomplete deleting batch
- **THEN** the overlap guard treats that page as incomplete and refuses the separate command

#### Scenario: Ordinary published batch can use command gate

- **WHEN** an ordinary batch is `complete` and `published` and its command evidence and scope are safe
- **THEN** `requestCleanup` retains its existing eligibility rule for that separate command
