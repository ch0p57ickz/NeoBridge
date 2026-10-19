# Spec Delta

## Purpose

Defines the SwiftUI menu-bar surface that presents pen connection and sync
state to the user without owning protocol or transport logic.

## ADDED Requirements

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

The app SHALL present the current connection state and, after a sync, the
decoded stroke, dot, and page counts.
The app SHALL distinguish scanning, connecting, verifying, syncing, complete,
and failed states. A completed result SHALL identify the notes read and state
that the data is held only in memory.

#### Scenario: Show sync results

- **WHEN** a sync completes
- **THEN** the menu-bar item or window shows the reported stroke, dot, and page counts

#### Scenario: Show progress during sync

- **WHEN** a transfer is in progress
- **THEN** the app indicates that syncing is underway instead of showing stale results

#### Scenario: Failed transfer has partial data

- **WHEN** a transfer fails after some packets arrive
- **THEN** the app presents the failure and does not label partial counts as a completed sync

### Requirement: Error presentation and retry

When a connection or sync step fails, the app SHALL show a human-readable error
and SHALL offer a retry action that starts a new scan.

#### Scenario: Retry after disconnect

- **WHEN** the connection drops mid-transfer and the app shows the error
- **THEN** choosing retry starts a new scan without restarting the app

#### Scenario: Cancel an active sync

- **WHEN** the user cancels an active connection or sync
- **THEN** the app stops the active scan or connection and returns to idle without reporting completion

### Requirement: Results are not persisted in this version

The app SHALL indicate that synced results are not saved, because durable
storage and export are deferred to a later change.

#### Scenario: Completed sync is labelled unsaved

- **WHEN** a sync completes
- **THEN** the app states that the results have not been saved to disk

#### Scenario: Read action is labelled clearly

- **WHEN** the app offers the action that retrieves offline strokes
- **THEN** it describes the action as reading pen data and does not imply that a durable import or export will occur
