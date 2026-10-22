# Spec Delta

## ADDED Requirements

### Requirement: Immediate menu sync

The menu SHALL offer **Sync Now** in every saved mode. The app SHALL accept it only when no read or pen choice is active, then start one read without changing the saved mode or interval. It SHALL use the existing pen choice, progress, result, cancellation, and failure presentation. The first accepted manual or automatic request SHALL own the single read.

#### Scenario: Request a read before the next automatic opportunity

- **WHEN** the user selects Sync Now while the app is idle and no pen choice is pending
- **THEN** one read begins immediately, without waiting for discovery or the saved interval

#### Scenario: Request a read while another read is active

- **WHEN** a read or pen choice is in progress
- **THEN** Sync Now is unavailable and no second read starts

#### Scenario: Several pens answer a manual request

- **WHEN** Sync Now discovers more than one matching pen
- **THEN** the app requests an explicit pen choice before continuing the read, including before any deleting transfer

#### Scenario: Manual read shares the existing status and result flow

- **WHEN** a Sync Now read runs, finishes, fails, or is cancelled
- **THEN** the menu status and Connection Details report that attempt under the same rules as a scheduled read

#### Scenario: Manual read and schedule do not overlap

- **WHEN** Sync Now is accepted before a pending automatic opportunity starts a read
- **THEN** the manual request starts the one read, the automatic opportunity starts no second read, and the next automatic interval is measured from the manual attempt's start

#### Scenario: Automatic read starts first

- **WHEN** an automatic opportunity starts a read before the user selects Sync Now
- **THEN** Sync Now is unavailable until that read and any pen choice settle, and selecting it does not start or queue another read

### Requirement: Saved mode controls immediate sync cleanup

Each accepted Sync Now request SHALL capture the saved mode at acceptance. **Sync and Delete** SHALL request the existing evidence-gated deleting route without a separate deletion command; **Sync and Retain** and **Pause** SHALL use a non-destructive read. A Sync Now read accepted in Pause SHALL leave automatic syncing paused after it settles unless the user changes the saved mode.

#### Scenario: Sync Now in Sync and Delete

- **WHEN** the user selects Sync Now while Sync and Delete is saved
- **THEN** the read requests a deleting transfer only if its export, evidence, pen identity, and durable-storage gates pass; otherwise it uses an ordinary read and reports why cleanup was skipped

#### Scenario: Sync Now in Sync and Retain

- **WHEN** the user selects Sync Now while Sync and Retain is saved
- **THEN** the read requests no deletion and retains the pen's data

#### Scenario: Sync Now in Pause

- **WHEN** the user selects Sync Now while Pause is saved
- **THEN** one ordinary non-destructive read runs, Pause remains selected unless the user changes it, and no automatic discovery or interval read resumes while Pause remains selected

#### Scenario: Mode changes during a manual read

- **WHEN** the user changes the saved mode after Sync Now has been accepted
- **THEN** that read keeps the mode captured at acceptance and the newly selected mode governs later opportunities, including whether automatic syncing resumes

#### Scenario: Export retry after a manual deleting read

- **WHEN** the user retries file publication after a Sync Now deleting read
- **THEN** the retry uses the saved library data and starts no new deleting transfer or separate deletion command
