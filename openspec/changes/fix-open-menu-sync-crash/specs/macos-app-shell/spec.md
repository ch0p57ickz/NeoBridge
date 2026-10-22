# Spec Delta

## ADDED Requirements

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
