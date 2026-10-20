# Spec Delta

## ADDED Requirements

### Requirement: Transfer option is evidence-backed and non-destructive

The session SHALL select the `0x23` transfer option from physical A1 trace
evidence. It SHALL NOT send an option that deletes pen data during transfer.
It SHALL prefer an incremental option only when known-stroke traces prove it
returns every new stroke and leaves uncommitted strokes retrievable after
interruption. Otherwise it MAY use an established non-destructive option; if
none exists, it SHALL report offline retrieval as unsupported.

#### Scenario: Transfer never deletes

- **WHEN** the session requests offline data for a discovered note
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

The session SHALL send a pen deletion command only for a scope proven by
physical A1 trace to contain exactly the data from a complete, durably imported
transfer whose requested exports all published successfully. A complete
transfer includes the final `0x24` end-position packet and outbound `0xA4`
Stop. The deletion gate SHALL require safe trace verdicts for command payload,
scope, response meaning, and interrupted-transfer behavior.

#### Scenario: Deletion follows a confirmed import

- **WHEN** a completed transfer has been stored, every requested export has published, and the evidence gate proves the command targets exactly that verified data
- **THEN** the session sends the deletion command for that scope

#### Scenario: Failed import sends no deletion

- **WHEN** a transfer ends before its final packet, fails to store, or is canceled
- **THEN** the bytes sent through the transport contain no `0x25` or `0x27` command

#### Scenario: A later note fails

- **WHEN** an earlier note was completely imported and published but a later note fails
- **THEN** the session MAY delete only the earlier note's verified data if the proven command scope cannot include the failed note, while the overall sync remains incomplete

#### Scenario: Deletion scope includes unverified data

- **WHEN** a command could also remove newer strokes or data from an incomplete note
- **THEN** the session sends no deletion command for that scope

#### Scenario: Deletion is requested once per stored transfer

- **WHEN** a stored transfer has already had its scoped deletion confirmed
- **THEN** the session sends no second deletion command for the same pages

## REMOVED Requirements

### Requirement: Destructive commands remain disabled

**Reason**: Replaced by `Deletion is ordered after confirmed storage`, which keeps
the deletion commands gated on evidence but permits them after a verified import is
confirmed. A prohibition with no enablement path left a user who does not want data
accumulating on the pen with no way to reclaim it.

**Migration**: No caller changes. Retention remains available, and the evidence
gate prevents deletion until the physical A1 safety conditions are established.
