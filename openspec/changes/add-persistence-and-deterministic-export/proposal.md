# Proposal

## Why

The current pen read ends with an in-memory summary, so completed strokes disappear when the app exits and users cannot use their notes outside NeoBridge. The physical A1 M0 protocol spike has established offline retrieval; this change makes a completed read durable and exportable while retaining the evidence gate for any new pen behavior.

## What Changes

- Add portable SQLite storage for canonical pages, strokes, replay-safe identities, and import progress.
- Add portable deterministic JSON, SVG, and Markdown page exports in a user-selected directory. Every non-empty page export produces all three formats, preserves differing existing files in a bounded backup history, and replaces each target atomically.
- Connect the existing pen read to verified storage and export, and update the macOS UI to report saved results and failures accurately.
- Add Linux fake-transport integration coverage for replay, interruption, and recovery, plus Mac runner and physical A1 acceptance steps.
- Keep pen cleanup in `keepOnPen` mode; no deletion commands are enabled.

## Capabilities

### New Capabilities

- `stroke-library`: Durable, replay-safe per-page storage and import lifecycle.
- `page-export`: Deterministic portable page files and safe publication.

### Modified Capabilities

- `macos-app-shell`: Replace the memory-only read contract with saved-result and export status presentation.

## Impact

Adds `Packages/NeoStorage`, `Packages/NeoExport`, and `Tests/Integration`; extends `NeoCore` domain boundaries, the macOS read runner and shell, `Scripts/test-portable.sh`, and the Mac build configuration. Linux remains the primary portable test host; the remote Mac runner gates SwiftUI, CoreBluetooth, `xcodebuild`, and physical A1 acceptance. The M0 protocol spike and real offline-stroke retrieval proof remain a blocking prerequisite for claiming end-to-end hardware support. No OCR, cloud sync, or concurrent multi-pen handling is included.
