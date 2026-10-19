# Tasks

## 1. Evidence and portable contracts

- [x] 1.1 Confirm `docs/protocol-a1.md` records the M0 physical A1 offline-stroke retrieval proof before UI work; verify the cited sanitized trace and hardware checklist match the supported read path.
  - Verified 2026-10-19: the M0 device record, trace steps, result table, and gate are present, and the trace's read order matches `PenSession`'s documented flow and the `Tests/Fixtures/a1-offline-session` fixture. One stale paragraph in `docs/protocol-a1.md` still calls the response-frame error code, the compression capability byte, and the reported minor `2.23` pending; all three have since landed (`PenFrameDecoder`, `OfflineData`, `ProtocolVersionPolicy.validatedMinors`), and the file also carries unrelated uncommitted edits from an earlier session, so it is left for a separate doc cleanup.
- [x] 1.2 Extend `NeoCore` import/store/export contracts for complete transfer data, separate saved/exported outcomes, retryable committed batches, and per-file publication results; verify `NeoCore` XCTest covers legal transitions and failure paths on Linux.
  - Verified on Linux: 44 NeoCore tests pass (was 31).

## 2. Durable stroke library

- [x] 2.1 Add `Packages/NeoStorage` with a portable SQLite WAL database, schema versioning, canonical page keys, and stroke records; verify package build and reopen tests on Linux.
  - Verified on Linux: build and reopen tests pass; SQLite is reached through a `systemLibrary` target (`CSQLite`).
- [x] 2.2 Implement transactional complete-batch import with reliable SHA-256 deduplication and preservation of unreliable strokes; verify replay and rollback XCTest cases.
- [x] 2.3 Persist import progress and the dormant `prepared -> requested -> confirmed` cleanup journal while keeping `keepOnPen` enforced; verify crash/reopen tests and that no deletion command is emitted.
- [x] 2.4 Document database location, schema/migration behavior, and recovery in the package README; verify the documented test command runs.
  - `cd Packages/NeoStorage && swift test` runs 31 tests on macOS and Linux.

## 3. Deterministic page export

- [x] 3.1 Add `Packages/NeoExport` with versioned JSON, SVG, and Markdown renderers for every non-empty page, omitting source and host metadata; verify byte-for-byte golden tests across reordered input, live/offline source, identical unreliable strokes, and process restarts on Linux, plus no output for an empty page.
  - Verified on Linux: 35 NeoExport tests pass.
- [x] 3.2 Add safe four-part filenames, XML/Markdown escaping, fixed numeric formatting, and sibling-temp atomic replacement with unchanged-file detection and three-version backup history; verify collisions, backup rotation, preservation failure, symlink refusal, interrupted multi-file publication, and retry.
- [x] 3.3 Verify JSON, SVG, and Markdown output excludes Bluetooth addresses, serial numbers, and authentication material using injected sentinel values; document the versioned output schema, file naming, backup behavior, and no in-file merge policy in the package README.
  - Sentinel exclusion is asserted at the renderer level in `NeoExportTests` and end-to-end in `Tests/Integration`.

## 4. App integration

- [x] 4.1 Carry `PenSessionResult.strokes` through the macOS runner into the import coordinator without losing summary counts; verify runner tests with a fake transport.
- [x] 4.2 Connect the app to the durable library and user-selected export directory with security-scoped bookmark access; verify app tests for save, export failure, retry, empty reads, and reopening the destination.
- [x] 4.3 Update menu and window states to distinguish reading, saving, exporting, saved, and failed outcomes and identify each file's publication result; verify UI state tests and remove the memory-only claim.
- [x] 4.4 Document the new save/export flow and retention behavior in `Apps/NeoBridgeMac/README.md`; verify the menu labels and documentation agree.
  - Documented: **Read and Save Pen Data**, **Retry Export**, **Choose Export Folder…**, the Saving and Exporting states, per-file results, and `keepOnPen` retention.

## 5. Integrated verification

- [x] 5.1 Add `Tests/Integration` fake-transport scenarios for offline import, duplicate replay, interrupted sync, and recovery using sanitized fixtures; verify they run on Linux without Apple frameworks.
  - Verified on Linux and macOS: 6 scenarios pass, including no deletion command and no device identity in the output.
- [x] 5.2 Update `Scripts/test-portable.sh` to build and test every portable package plus integration tests and check import boundaries and pinned dependencies; verify the script passes on Linux.
  - Verified on Linux: all five packages build with pinned dependencies, import no Apple-only framework, and pass; the SQLite header precondition is checked first.
- [x] 5.3 Run `Scripts/remote-mac-build.sh` on the Mac runner with its Xcode gate enabled; record the passing portable, SwiftUI, CoreBluetooth, and `xcodebuild` results.
  - Recorded in `docs/portable-verification.md`: portable suites, SwiftPM release build, `xcodebuild` gate, and the assembled ad-hoc-signed bundle all pass.
- [ ] 5.4 Run physical A1 save-and-export acceptance with a sanitized transcript, confirm output bytes and `keepOnPen` outbound commands, and record the result in `Tests/Hardware/README.md`; leave this task unchecked if hardware is unavailable.
  - Blocked: no physical A1 pen is available to this run. The headless acceptance path (`NEOBRIDGE_ACCEPTANCE_TRACE` plus `NEOBRIDGE_EXPORT_DIRECTORY`) is implemented and the deletion/`keepOnPen` behavior is covered by the portable session and integration tests, but the on-device save-and-export bytes are not yet confirmed. Leave unchecked until a pen is available.
