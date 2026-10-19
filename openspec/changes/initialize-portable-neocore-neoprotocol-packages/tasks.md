## 1. Portable package setup

- [x] 1.1 Create `Packages/NeoCore` and `Packages/NeoProtocol` SwiftPM manifests and minimal targets; verify `swift test` succeeds in each package on Linux.
- [x] 1.2 Add `Scripts/test-portable.sh` to run both package suites and a forbidden-import check; verify the script passes on Linux without Xcode or Apple frameworks.

## 2. NeoCore domain

- [x] 2.1 Implement canonical section, owner, book, and page identity plus normalized pen event and stroke types; verify distinct tuple components produce distinct page keys in unit tests.
- [x] 2.2 Implement stroke assembly with invalid-sequence results for point-before-down and page-change cases, and an incomplete result for missing up; verify all three cases and valid point order in Linux tests.
- [x] 2.3 Implement versioned canonical stroke encoding using full page identity, pen-origin start time, and ordered integer point coordinates, pen-time offsets, and pressure; verify golden SHA-256 vectors, live/offline replay equivalence, changed-field separation, and no automatic cross-source deduplication when pen time is unreliable.
- [x] 2.4 Add portable domain interfaces for future import state and storage/export boundaries; verify a fake implementation can exercise state transitions without platform imports.

## 3. NeoProtocol fixtures

- [x] 3.1 Implement platform-neutral `PenTransport`, protocol 2.x framing, explicit parse errors, and observed-version dispatch; verify valid, truncated, unsupported-version, and frame/input size-limit tests, including recovery for a following valid frame.
- [x] 3.2 Add sanitized fixture files with SDK or A1 provenance, model, firmware, observed version, capture date, expected output, and evidence level; verify repeated results and a review that excludes addresses, serials, authentication material, and personal handwriting.
- [x] 3.3 Add a fake transport and Linux integration fixtures for offline import, duplicate replay, interrupted sync, and recovery; verify all four scenarios pass without BLE hardware.
- [x] 3.4 Gate each handshake, authentication, and offline command on official SDK wire evidence or physical A1 validation plus a fixture test; verify provisional mappings cannot send production requests or emit completed strokes, while unknown commands and versions return unsupported results.

## 4. Hardware gate and platform checks

- [ ] 4.1 Complete the M0 protocol spike in `docs/protocol-a1.md` with A1 model, firmware, reported protocol version, capture date, command evidence, and a real offline retrieval trace; verify decoded page and points match a known written test mark, no deletion request was sent, and the evidence is reviewed before UI implementation.

  _Blocked: requires a physical A1. `docs/protocol-a1.md` records the SDK wire evidence, the command evidence table, the sanitized fixtures, and the exact trace procedure; every hardware-dependent field is marked pending._

- [x] 4.2 Run `Scripts/test-portable.sh` on Linux and record the passing command output; verify no Apple imports appear in portable packages. Recorded in `docs/portable-verification.md`.
- [ ] 4.3 Run `xcodebuild` and SwiftUI compilation on the remote Mac runner when the app target exists, then run physical A1 acceptance tests there; verify results are recorded and pen cleanup remains in `keepOnPen` mode until hardware acceptance passes.

  _Blocked: this change adds no app target, and the remote Mac runner and physical A1 are not available from this host. `PenCleanupPolicy.deletionEnabled` is hard-coded `false`, so cleanup stays in `keepOnPen` mode._
