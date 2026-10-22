# Proposal

## Why

Automatic discovery and interval syncs leave no way to request an immediate read from the menu. A Sync Now command lets the user start one read without changing the saved schedule or mode.

## What Changes

- Add **Sync Now** to the menu. It starts one read immediately when no read or pen choice is in progress, using the saved mode at acceptance. If a scheduled read starts first, the command is unavailable; if Sync Now starts first, that read is the one attempt.
- In **Sync and Delete**, the read requests the existing evidence-gated deleting transfer. In **Sync and Retain**, it uses an ordinary non-destructive read. In **Pause**, it uses an ordinary non-destructive read and leaves automatic syncing paused.
- Keep the existing status, result, pen-choice, cancellation, export, and error behavior for the requested read. Manual requests use the same single-flight radio handoff as scheduled reads and do not change the saved interval.
- Preserve the M0 physical A1 evidence gate and the later per-route safety verdicts. The command itself never establishes that deletion is safe or complete.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `macos-app-shell`: Add a user-requested menu sync that follows the saved mode, with a retaining one-time read during Pause.

## Impact

The change affects `PenSyncMenu`, the app-owned coordinator and controller in `Apps/NeoBridgeMac`, their fake-clock and fake-transport tests, and menu documentation. It adds no protocol command, portable-package dependency, or cloud service. Linux tests can verify scheduling and authorization; the remote Mac runner must build the SwiftUI app and check the menu. Physical A1 acceptance remains the gate for claims about pen deletion.
