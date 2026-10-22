# Spec Delta

## MODIFIED Requirements

### Requirement: Accurate save and export labelling

The app SHALL label each read according to its actual storage and export outcome. It SHALL NOT claim a read is saved when storage fails, and SHALL NOT claim an export succeeded when publication fails. It SHALL distinguish a durable packet prefix in a partial deleting read from a completed saved read. It SHALL report pen removal only as an evidence-backed acknowledged prefix, not as confirmed whole-note deletion when a transfer fails (`openspec/specs/macos-app-shell/spec.md:48-72`).

#### Scenario: Completed sync is labelled saved

- **WHEN** a read commits its strokes and publishes requested files
- **THEN** the app states that results were saved and shows the export destination

#### Scenario: Read action is labelled clearly

- **WHEN** the app offers the action that retrieves offline strokes for durable import
- **THEN** it describes the action as saving the pen data

#### Scenario: Export fails after storage commit

- **WHEN** the library commit succeeds but file publication fails
- **THEN** the app distinguishes saved library data from the failed export, identifies each file that was published and each file that failed, and offers a retry

#### Scenario: Read finds no strokes

- **WHEN** a complete read finds no strokes
- **THEN** the app reports that no strokes were found and does not claim that files were exported

#### Scenario: Partial deleting read

- **WHEN** a deleting transfer stops after at least one acknowledged packet
- **THEN** the app presents the read as partial rather than as a completed sync, reports partial progress, identifies durable library data and export status, warns that some pen data may already be removed, and offers a fresh read and export retry

### Requirement: Default cleanup and retention choice are visible

The app SHALL show cleanup as the per-sync default intent, allow retention, and require confirmation before a deleting transfer. Availability SHALL require a requested export, safe transfer evidence, and durable packet storage; confirmation SHALL authorize only this sync. The choice text SHALL state that each acknowledged packet is removed as the read progresses after library storage, before export may finish. It SHALL report retention, an acknowledged prefix, completed reclamation, skipped cleanup with a reason, or an outstanding separate command accurately.

#### Scenario: Default cleanup is presented

- **WHEN** a sync is about to start and the user has made no choice
- **THEN** the app states that cleanup is intended but requires confirmation, explains packet-by-packet removal and re-export from the local library, and offers retention

#### Scenario: Retention is chosen

- **WHEN** the user chooses retention
- **THEN** the sync requests no deletion and the app shows that the pen's strokes will be kept

#### Scenario: Completed sync reports the pen's copy

- **WHEN** a deleting transfer completes and all packets were durably committed before acknowledgement
- **THEN** the app reports the note was removed from the pen according to the validated transfer behavior and remains available in the library

#### Scenario: Cleanup is skipped

- **WHEN** the evidence gate, confirmation, or durable packet storage precondition prevents a deleting transfer
- **THEN** the app reports that no deleting transfer started and names the blocking condition

#### Scenario: Unconfirmed deletion is reported as outstanding

- **WHEN** a separate deletion command was sent but its matching confirmation was not received
- **THEN** the app reports the command as outstanding rather than as reclamation

#### Scenario: Consent is for one sync

- **WHEN** a user confirms cleanup and later starts another sync
- **THEN** the later sync requires its own confirmation before option `0x01` can be sent

#### Scenario: Export fails after removal

- **WHEN** acknowledged packets were removed during a deleting read and file publication fails
- **THEN** the app reports that the local library holds the saved strokes, warns that their pen copy may be gone, and offers export retry without implying the pen is a fallback

#### Scenario: Cleanup availability names the transfer gate

- **WHEN** the user prepares a deleting read and no export was requested, transfer evidence or pen identity mismatches, or durable packet storage is unavailable
- **THEN** the cleanup availability and reason shown by the shell name that transfer-specific blocker rather than the closed `0x25` command scope

#### Scenario: No export keeps the pen copy

- **WHEN** the user starts a sync without requesting file export
- **THEN** the shell reports that cleanup is unavailable because no export was requested and starts an ordinary non-destructive read without offering a deleting transfer

#### Scenario: Retry export does not delete again

- **WHEN** the user retries file publication for a partial or complete deleting batch
- **THEN** the shell describes file publication from the library and sends no new deleting transfer or separate deletion command
