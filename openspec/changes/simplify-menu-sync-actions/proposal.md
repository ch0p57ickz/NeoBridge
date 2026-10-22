# Proposal

## Why

The menu bar currently requires several clicks and long cleanup explanations for each read. The app should instead remember how to sync, discover the pen automatically, and show detailed information only when requested.

## What Changes

- Save a persistent mode: **Sync and Delete**, **Sync and Retain**, or **Pause**. First install defaults to Sync and Delete; later launches restore the last mode. The saved Delete mode authorizes eligible deleting reads without another selection or confirmation click.
- Start pen discovery when an unpaused app opens, sync when the pen appears, and sync periodically while it remains available. The interval defaults to five minutes and is saved; the menu offers 1, 5, 15, and 30 minutes. Do not overlap reads or repeatedly sync the same pen appearance.
- Paused stops future discovery and sync attempts without cancelling a read already in progress. Choosing Delete or Retain resumes automatic syncing in that mode.
- Reduce the menu to one compact status line plus the saved settings: remove the informational text, the separate cleanup choice, and the confirmation command. Keep Connection Details for outcomes, export folder selection, and detailed failures; retain contextual cancel and retry controls where needed. (Amended 2026-10-21: the first implementation removed the status line as well; the owner asked for it back, so the menu carries exactly one.)
- Keep the existing evidence, export, durable-storage, and pen-identity gates. A blocked deleting transfer uses an ordinary non-destructive read and reports why deletion did not occur. Sync and Delete sends no later separate deletion command, including after fallback or export retry. A partial deleting read reports only the acknowledged prefix.
- Align the optional details window with the same saved mode and automatic sync lifecycle.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `macos-app-shell`: Define persistent sync mode and interval, automatic discovery and periodic reads, pause behavior, concise menu presentation, and accurate gated outcomes.

## Impact

This changes the SwiftUI menu and details window, app lifecycle, Bluetooth discovery scheduling, persistent preferences, shell controller, and related tests. It does not change portable protocol framing, storage, or export behavior. Linux tests exercise scheduling and shell state with fake transport and clock; the Mac runner must build the SwiftUI app and verify discovery. The existing M0 physical A1 protocol evidence gate remains authoritative for deleting transfers, and the outstanding app-level physical acceptance task remains open.
