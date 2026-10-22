# Spec Delta

## ADDED Requirements

### Requirement: Persistent sync controls

The menu SHALL offer **Sync and Delete**, **Sync and Retain**, and **Pause** as persistent settings. First install SHALL select Delete; later launches SHALL restore the last saved setting. Selecting Delete or Retain SHALL change the mode and enable automatic sync without requiring that setting to be chosen again. The menu SHALL offer interval choices of 1, 5, 15, and 30 minutes, defaulting to 5, and SHALL restore the last saved interval.

#### Scenario: First launch defaults to delete and five minutes

- **WHEN** the app launches without saved sync preferences
- **THEN** Sync and Delete and a five-minute interval are selected, and automatic discovery starts without another click

#### Scenario: Reopen with saved settings

- **WHEN** the app relaunches after the user selected Retain, Delete, or Pause and an interval
- **THEN** the menu restores both saved selections and the app follows that mode without resetting them to defaults

#### Scenario: Choose retention

- **WHEN** the user selects Sync and Retain
- **THEN** subsequent automatic reads use the non-destructive route and request no deletion

#### Scenario: Pause prevents future syncs

- **WHEN** the user selects Pause
- **THEN** Pause is saved, pending automatic discovery stops, and no automatic sync begins until the user selects Sync and Delete or Sync and Retain; a separate Sync Now request may still start one retaining read

#### Scenario: Pause during a sync

- **WHEN** the user selects Pause while a sync is active
- **THEN** that sync continues and no later automatic sync begins while Pause remains selected

#### Scenario: Resume by choosing a mode

- **WHEN** Pause is selected and the user selects Sync and Delete or Sync and Retain
- **THEN** the app saves the selected mode and resumes automatic discovery and scheduling in that mode

#### Scenario: Change the interval

- **WHEN** the user selects a different menu interval
- **THEN** the app saves it and uses it for subsequent periodic sync opportunities without starting a second overlapping read

### Requirement: Automatic sync scheduling

While unpaused and running, the app SHALL discover the pen and start a sync when it appears, then offer another sync at each saved interval while available. It SHALL run at most one sync at a time and SHALL NOT repeat a completed read immediately for the same continuous appearance. A missed interval during an active read SHALL be coalesced into the next eligible opportunity. Failure or absence SHALL be reported in Connection Details without a rapid retry loop.

#### Scenario: Pen appears after launch

- **WHEN** the app is unpaused and a compatible pen starts advertising
- **THEN** the app starts one sync using the saved mode without requiring a menu action

#### Scenario: Periodic sync while available

- **WHEN** the pen remains available and the saved interval elapses after the previous attempt began
- **THEN** the app starts another sync using the saved mode unless one is already active

#### Scenario: No overlapping or immediate repeat

- **WHEN** a sync is active or has just completed during the same continuous pen appearance
- **THEN** the app starts no second sync until the next interval or a genuine disappearance and reappearance

#### Scenario: Pen absent or read fails

- **WHEN** a discovery window finds no pen or a read fails
- **THEN** the app keeps its mode and interval, records the condition in Connection Details, and schedules the next eligible attempt without rapid repeated scans

#### Scenario: Multiple pens found

- **WHEN** more than one matching pen is discovered
- **THEN** the app requests an explicit pen choice and starts no deleting transfer until a pen is chosen

#### Scenario: Open details

- **WHEN** the user selects Connection Details
- **THEN** the app opens the existing details window with connection, export destination, result, and failure information

#### Scenario: Details window starts a sync

- **WHEN** the user changes the sync mode or interval from the details window
- **THEN** it reflects the same saved setting and automatic behavior as the menu

### Requirement: Compact menu status

The menu SHALL show exactly one status line and no other status information. It SHALL read **Idle** before any attempt settles, **Syncing** while a read or a pen choice is pending, **Paused** while Pause is selected and no read is in flight, the last completed read with its elapsed time, **Not Detected** when no pen advertised the expected name, and **Failed** otherwise.

#### Scenario: Menu carries one status line

- **WHEN** the user opens the menu before or after a sync
- **THEN** exactly one status line appears

#### Scenario: A missing pen is its own status

- **WHEN** the last attempt found no pen advertising the expected name
- **THEN** the status line reads Not Detected and Connection Details names the condition

#### Scenario: Another failure is not reported as a missing pen

- **WHEN** the last attempt failed for a reason other than a missing pen
- **THEN** the status line reads Failed and Connection Details names the reason

#### Scenario: A completed read is dated

- **WHEN** the last read completed and no attempt has failed since
- **THEN** the status line shows how long ago it happened, and the elapsed time stays correct as time passes

#### Scenario: A read that carried no strokes still counts

- **WHEN** the pen was reached and read but carried no stroke to store
- **THEN** the status line dates that read rather than reporting the pen as absent or as idle

#### Scenario: A failed export retry leaves the date alone

- **WHEN** an export retry fails after a read already completed
- **THEN** the status line still dates that read

#### Scenario: A cancelled read keeps the previous status

- **WHEN** a read is cancelled
- **THEN** the status line keeps the status it showed before that read started

#### Scenario: The paused mode is stated

- **WHEN** Pause is selected and no read is in flight
- **THEN** the status line reads Paused rather than showing an earlier result

#### Scenario: An attempt in flight outranks the paused mode

- **WHEN** a read is running or a pen choice is pending
- **THEN** the status line reads Syncing, whatever the saved mode is

### Requirement: Menu status detail stays in Connection Details

Counts, export paths, cleanup explanations, and failure details SHALL be absent from the menu and available through Connection Details.

#### Scenario: The menu is not a report

- **WHEN** the user opens the menu after a read that reported counts, a partial result, a skipped cleanup, or a failed file
- **THEN** none of that detail appears in the menu, and Connection Details still shows it

## MODIFIED Requirements

### Requirement: Default cleanup and retention choice are visible

The app SHALL default to Sync and Delete on install and retain the selected mode across launches. The saved Delete mode SHALL authorize eligible automatic deleting transfers without per-read confirmation; each transfer still requires a requested export, safe transfer evidence, matching pen identity, and durable packet storage. Sync and Delete SHALL send no separate deletion command after a read or export retry. The app SHALL report retention, acknowledged removal, or skipped cleanup accurately.

#### Scenario: Default cleanup is presented

- **WHEN** the app opens on first install
- **THEN** Sync and Delete is selected and automatic discovery starts

#### Scenario: Retention is chosen

- **WHEN** the user chooses Sync and Retain
- **THEN** the sync requests no deletion and the app reports that the pen's strokes were kept

#### Scenario: Completed sync reports the pen's copy

- **WHEN** a deleting transfer completes and all packets were durably committed before acknowledgement
- **THEN** the app reports the note was removed from the pen according to validated transfer behavior and remains available in the library

#### Scenario: Cleanup is skipped

- **WHEN** the evidence gate, requested export, or durable packet storage precondition prevents a deleting transfer
- **THEN** the app performs an ordinary non-destructive read, sends no separate deletion command, and reports the blocking reason in Connection Details

#### Scenario: Unconfirmed deletion is reported as outstanding

- **WHEN** a separate deletion command was sent but its matching confirmation was not received
- **THEN** the app reports the command as outstanding rather than as reclamation

#### Scenario: No separate deletion after a direct sync

- **WHEN** a Sync and Delete read completes, falls back to an ordinary read, or later retries file export
- **THEN** that sync sends no separate deletion command

#### Scenario: Saved delete mode applies to later syncs

- **WHEN** a later automatic sync starts while Sync and Delete remains saved
- **THEN** the app may request the deleting route without another click only if all transfer safety gates pass

#### Scenario: Export fails after removal

- **WHEN** acknowledged packets were removed during a deleting read and file publication fails
- **THEN** the app reports that the local library holds the saved strokes, warns that their pen copy may be gone, and offers export retry without implying the pen is a fallback

#### Scenario: Cleanup availability names the transfer gate

- **WHEN** automatic Sync and Delete runs but export was not requested, transfer evidence or pen identity mismatches, or durable packet storage is unavailable
- **THEN** Connection Details names that transfer-specific blocker rather than the closed separate-command scope

#### Scenario: No export keeps the pen copy

- **WHEN** automatic Sync and Delete runs without a requested file export
- **THEN** the app starts an ordinary non-destructive read and reports in Connection Details that cleanup was unavailable

#### Scenario: Retry export does not delete again

- **WHEN** the user retries file publication for a partial or complete deleting batch
- **THEN** the app publishes from the library and sends no new deleting transfer or separate deletion command
