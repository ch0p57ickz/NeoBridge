# Proposal

## Why

The A1 reports its battery, charging state, and used storage through a verified pen-state exchange, but NeoBridge does not show them. Users cannot see whether the pen needs charging or has room for more strokes.

## What Changes

- Query `0x04` after the version handshake and decode the `0x84` response.
- Show battery percentage, charging state, and pen storage used in Connection Details after a successful read. The later compact-menu decision keeps these measurements out of the menu.
- Record the physical A1 evidence and cover decoding and session behavior with portable tests.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pen-session`: Read the evidence-backed pen state during an A1 session.
- `macos-app-shell`: Present the measured battery and storage values without retaining stale readings as current.

## Impact

The portable NeoProtocol package gains a pen-state model and decoder. The macOS runner passes the result through its controller to SwiftUI. The M0 physical A1 probe is the evidence gate for `0x04` and `0x84`; the existing offline retrieval gate stays in force. Portable tests run on Linux, while the macOS app and physical acceptance require the Mac runner.
