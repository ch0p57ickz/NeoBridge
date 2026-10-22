# Proposal

## Why

NeoBridgeMac can crash when a read changes state while its menu is open. Two user-supplied macOS 27.0.1 reports (2026-10-21 at 22:04 and 22:25) and a later macOS 27.2 report (22:59) show the main thread exhausting its stack in repeated SwiftUI menu-item updates. The later crash occurred during menu inspection on a runner without a physical A1 available, so pen transfer is not a prerequisite for the failure; the exact menu element responsible remains unproven.

## What Changes

- Compare the open-menu crash against targeted menu variants and record the limits of that isolation. Replace the SwiftUI menu host with a native status-item menu whose items update in place during a read.
- Make the menu remain responsive through discovery, read progress, completion, failure, and cancellation, whether it is open or closed. Preserve the existing single status line, saved mode and interval, and accurate results.
- Add regression coverage for controller state transitions and macOS UI acceptance that first exercises a Sync Now read with no pen available, then checks one automatic read with the menu open. Use the implemented Sync Now path; its remaining UI and physical-pen acceptance can follow the crash fix.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `macos-app-shell`: Require the open menu to remain stable and usable while sync state and menu command availability change.

## Impact

The change is scoped to the menu presentation in `Apps/NeoBridgeMac`, its shell-state tests, and macOS acceptance guidance. It should not change the pen protocol, storage or export contracts, sync scheduling, or the evidence-gated deletion route. Portable tests run on Linux; the SwiftUI reproduction and full Xcode-gated build require the Mac runner. Existing physical A1 protocol evidence in `docs/protocol-a1.md` remains the exit gate for claims about pen transfer and cleanup behavior.
