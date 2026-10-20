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
claim an export succeeded when publication fails.

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

### Requirement: Error presentation and retry

When a connection or sync step fails, the app SHALL show a human-readable error
and SHALL offer a retry action that starts a new scan.

#### Scenario: Retry after disconnect

- **WHEN** the connection drops mid-transfer and the app shows the error
- **THEN** choosing retry starts a new scan without restarting the app

#### Scenario: Cancel an active sync

- **WHEN** the user cancels an active connection or sync
- **THEN** the app stops the active scan or connection and returns to idle without reporting completion
