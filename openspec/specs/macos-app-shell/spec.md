# macos-app-shell Specification

## Purpose

Defines the SwiftUI menu-bar surface that presents pen connection and sync
state to the user without owning protocol or transport logic.

## Requirements

### Requirement: Menu-bar presence

The app SHALL run as a macOS menu-bar item and SHALL offer an optional window
for connection details and sync results.

#### Scenario: Launch as a menu-bar app

- **WHEN** the app launches
- **THEN** a menu-bar item is present and the app does not require a dock window to operate

#### Scenario: Open the details window

- **WHEN** the user chooses the details command from the menu-bar item
- **THEN** the app shows the connection and sync window

### Requirement: Connection and sync presentation

The app SHALL present the current connection state and, after a read, the
decoded stroke, dot, and page counts. The app SHALL distinguish scanning,
connecting, verifying, syncing, saving, exporting, complete, and failed states.
A completed result SHALL identify the notes read and state where the data was
saved.

#### Scenario: Show sync results

- **WHEN** a read, save, and requested export complete
- **THEN** the menu-bar item or window shows the reported stroke, dot, and page counts and identifies the saved result

#### Scenario: Show progress during sync

- **WHEN** a transfer or subsequent save or export is in progress
- **THEN** the app indicates the current operation instead of showing stale results

#### Scenario: Failed transfer has partial data

- **WHEN** a transfer fails after some packets arrive
- **THEN** the app presents the failure and does not label partial counts as a completed sync

### Requirement: Accurate save and export labelling

The app SHALL label each read according to its actual storage and export
outcome. It SHALL NOT claim a read is saved when storage fails, and SHALL NOT
claim an export succeeded when publication fails. It SHALL distinguish a durable
packet prefix in a partial deleting read from a completed saved read. It SHALL
report pen removal only as an evidence-backed acknowledged prefix, not as
confirmed whole-note deletion when a transfer fails
(`openspec/specs/macos-app-shell/spec.md:48-72`).

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

### Requirement: Error presentation and retry

When a connection or sync step fails, the app SHALL show a human-readable error
and SHALL offer a retry action that starts a new scan.

#### Scenario: Retry after disconnect

- **WHEN** the connection drops mid-transfer and the app shows the error
- **THEN** choosing retry starts a new scan without restarting the app

#### Scenario: Cancel an active sync

- **WHEN** the user cancels an active connection or sync
- **THEN** the app stops the active scan or connection and returns to idle without reporting completion

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

### Requirement: Persistent sync controls

The menu SHALL offer **Sync and Delete**, **Sync and Retain**, and **Pause** as
persistent settings. First install SHALL select Delete; later launches SHALL
restore the last saved setting. Selecting Delete or Retain SHALL change the mode
and enable automatic sync without requiring that setting to be chosen again. The
menu SHALL offer interval choices of 1, 5, 15, and 30 minutes, defaulting to 5,
and SHALL restore the last saved interval.

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

While unpaused and running, the app SHALL discover the pen and start a sync when
it appears, then offer another sync at each saved interval while available. It
SHALL run at most one sync at a time and SHALL NOT repeat a completed read
immediately for the same continuous appearance. A missed interval during an
active read SHALL be coalesced into the next eligible opportunity. Failure or
absence SHALL be reported in Connection Details without a rapid retry loop.

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

The menu SHALL show exactly one status line and no other status information. It
SHALL read **Idle** before any attempt settles, **Syncing** while a read or a pen
choice is pending, **Paused** while Pause is selected and no read is in flight,
the last completed read with its elapsed time, **Not Detected** when no pen
advertised the expected name, and **Failed** otherwise.

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

Counts, export paths, cleanup explanations, and failure details SHALL be absent
from the menu and available through Connection Details.

#### Scenario: The menu is not a report

- **WHEN** the user opens the menu after a read that reported counts, a partial result, a skipped cleanup, or a failed file
- **THEN** none of that detail appears in the menu, and Connection Details still shows it

### Requirement: Pen battery and storage presentation

After a successful A1 read, the app SHALL show battery percentage, charging
state, and percentage of pen storage used in Connection Details. It
SHALL clear the previous measurement when a new read begins and SHALL not show an
unmeasured value as current.

#### Scenario: Successful state query

- **WHEN** the pen reports 94% battery, not charging, and 10% storage used
- **THEN** Connection Details shows those measurements with their correct labels

#### Scenario: Read begins again

- **WHEN** a new read begins after an earlier completed read
- **THEN** the earlier battery and storage measurements are no longer shown as current

### Requirement: Stable open menu during sync updates

While the user has not selected a menu command, the displayed menu SHALL remain open and usable without terminating the app as connection, read, save, export, or command-availability state changes. It SHALL show the applicable single status line and controls for the current attempt. Selecting a command MAY dismiss the menu according to macOS menu behavior; the app SHALL remain running.

#### Scenario: Automatic read starts with the menu open

- **WHEN** an automatic read starts while the menu is open
- **THEN** the app remains running, the menu remains usable, and its status shows Syncing while the read or pen choice is active

#### Scenario: Read settles with the menu open

- **WHEN** a read completes, fails, or is cancelled while the menu is open
- **THEN** the app remains running and the still-open menu presents the resulting status and applicable commands without requiring a relaunch

#### Scenario: Elapsed status changes with the menu open

- **WHEN** the menu remains open after a completed read and its elapsed-time label changes
- **THEN** the menu remains responsive and its single status line continues to describe when the last completed read occurred

#### Scenario: Sync Now read changes an open menu

- **WHEN** the user selects Sync Now, reopens the menu during that read, and keeps it open as the read changes state
- **THEN** the same stability and status behavior applies as for an automatic read

#### Scenario: No pen is found during an open-menu read

- **WHEN** the user selects Sync Now with no compatible pen available and reopens the menu while the read is scanning
- **THEN** the menu remains open and usable through the scan and its result, the app remains running, and the status changes from Syncing to Not Detected when no pen is found

#### Scenario: Command selection dismisses the menu

- **WHEN** the user selects an available menu command while a read is active
- **THEN** the command takes effect and the app remains running even if macOS dismisses the menu

#### Scenario: Automatic read changes an open menu

- **WHEN** Sync and Retain is selected and one scheduled read starts and settles while the menu is open
- **THEN** the app remains running, the menu remains usable, and its status and available commands reflect the active read and its result
