# Design

## Context

See `proposal.md` and `specs/macos-app-shell/spec.md`. `PenSyncCoordinator` discovers a pen and starts automatic or requested reads; `PenSyncController` publishes phase and outcome through `@Observable`; the original `PenSyncMenu` renders a `.menu`-style `MenuBarExtra`. Its status uses a relative-date `Text`, and its Cancel, pen-choice, and Retry commands appear conditionally. All three available crash reports show `EXC_BAD_ACCESS` from stack exhaustion with repeated `MenuBehavior.menuHostDidChangeMenuItems` and `ViewGraphRootValueUpdater.render` frames while an AppKit menu tracking session is active. The latest report is from macOS 27.2 during menu inspection without a physical A1 available. None identifies a specific `PenSyncMenu` expression as the cause.

The current XCTest suites exercise controller and coordinator behavior but cannot render the menu-bar menu. Headless acceptance skips presentation, so a passing headless read cannot close this crash. The Sync Now implementation and Xcode-gated bundle are available, but its menu mode-preservation and physical-A1 acceptance remain unchecked because the crash and hardware availability block them. This fix must not depend on those tasks being completed first. Selecting Sync Now may dismiss the menu, so acceptance reopens it during the requested read.

## Goals / Non-Goals

**Goals:**

- Identify the update boundary implicated in recursive rendering on the affected macOS release before selecting the final UI change.
- Keep live status and applicable commands accurate while a menu is open through automatic and user-requested reads.
- Verify the rendered menu on macOS as well as the controller/coordinator behavior in tests.

**Non-Goals:**

- Change BLE framing, scheduling intervals, import/export outcomes, or cleanup authorization.
- Move AppKit or SwiftUI into portable packages.
- Claim a physical A1 transfer or deletion behavior from a UI crash test alone.

## Decisions

### Reproduce and isolate at the menu boundary

The short no-pen reproduction on macOS 27.2 selected Sync Now, reopened the menu during scanning, and produced the same crash signature on cycle 6 of the baseline probe. A static-content menu survived a targeted probe while several live-content variants crashed. This implicates the SwiftUI menu host live-update path, but does not identify one faulty expression. Closed-menu reads had survived before the change. The native-menu candidate survived two short no-pen cycles on macOS 27.2; the observed settled states were Failed and Not Detected. One Retain-mode Sync Now read with a powered-on A1 kept the menu open through Syncing and Synced. No macOS 27.0.1 runner was available. Longer everyday use can provide follow-up evidence without becoming an acceptance gate.

Alternative: change the controller or BLE pipeline first. The crash stack is in SwiftUI's menu host and the closed-menu read succeeds, so the menu boundary is the narrower starting point.

### Stabilize menu presentation without weakening the sync contract

Keep `PenSyncController` and `PenSyncCoordinator` as the sources of read state. Use `NSStatusItem` and `NSMenu` to avoid SwiftUI's recursive `MainMenuItemHost` update path. Keep fixed menu-item identities stable and change their titles, checkmarks, enabled states, and visibility in place. Build numbered pen choices only when candidates change. Map controller state to menu content in `PenSyncMenuPresentation`, which core tests can exercise. Refresh the elapsed label with a timer only while a completed read is shown and the menu is open. A suppressed SwiftUI window scene retains Connection Details; a scene command captures `openWindow` at launch for the AppKit menu. Do not suppress read, save, export, or cleanup state transitions to avoid a UI refresh.

Alternative: freeze all menu data until the user closes and reopens it. That would hide active progress and violate the open-menu behavior in the delta spec.

### Test the UI failure on the platform that renders it

Add focused state-transition tests for menu-facing values where they can catch regressions. First use a Mac GUI acceptance run, manually or with the existing accessibility-enabled `System Events` harness, that opens the menu during a no-pen Sync Now scan and observes Syncing through Not Detected without an app crash. Verify a visible command can then be selected and acts normally; selection itself may dismiss the menu. Check failure and cancellation without assuming the menu remains open after a command is selected. Separately, when a physical A1 is available, hold the menu open through one automatic Retain read and its completion, and check that an elapsed-time status update remains usable. `Scripts/remote-mac-build.sh` with the Xcode gate and `Scripts/test-portable.sh` remain build gates, but neither substitutes for rendered-menu acceptance.

## Risks / Trade-offs

- [The crash is intermittent or OS-specific] -> Preserve the crash metadata and reproduction sequence; run repeated open-menu cycles on the affected macOS release and record the exact OS/build used for acceptance.
- [A layout change fixes the crash but changes command reachability] -> Verify Cancel, pen choice, Retry Export, saved modes, interval, Connection Details, and Sync Now when present during and after a read.
- [A UI-only acceptance run accidentally exercises cleanup] -> Use Sync and Retain for the crash reproduction. Any separate Delete acceptance must satisfy the existing physical A1 evidence gates and preserve the prepared -> requested -> confirmed journal semantics.
- [A timed label fix becomes stale] -> Check the elapsed status while the menu remains open over a time boundary.

## Migration Plan

No data or preference migration is needed. Implement and verify the UI correction, then package the app through the existing Mac build. Rollback restores the previous menu presentation only; stored library data, exports, and pen sync settings remain intact.
