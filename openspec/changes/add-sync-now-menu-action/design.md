# Design

## Context

See `proposal.md` for the user need and `specs/macos-app-shell/spec.md` for the behavior contract. `PenSyncMenu` currently exposes saved modes, the interval, and contextual commands. `PenSyncCoordinator` owns observation and interval opportunities, then hands a read to `PenSyncController`. The controller's `readAutomatically()` refuses Pause, while its direct `readPenData()` uses per-read authorization intended for headless acceptance and tests. The two routes cannot be substituted for a paused menu request.

## Goals / Non-Goals

**Goals:**

- Give menu requests and automatic opportunities one serialized entry point to the Bluetooth adapter and attempt controller.
- Capture the selected cleanup behavior for one request without changing persistent settings or the headless acceptance API.
- Keep the next scheduled opportunity paced from the latest attempt, including a manual one.

**Non-Goals:**

- Change protocol framing, deletion evidence, the library schema, or export formats.
- Add a separate cleanup command after a read.

## Decisions

1. `PenSyncMenu` calls a new app-owned `PenSyncCoordinator` request method. The coordinator accepts a request only when the controller is neither busy nor awaiting a pen choice. It serializes the request with its observation and interval loop: whichever request starts the read first owns the attempt. If an automatic read starts first, Sync Now is unavailable and no manual read is queued. If Sync Now is accepted first, its read wins and the pending automatic opportunity starts no second read. The coordinator stops observation before the bounded selection scan and resumes it only if the saved mode is automatic. Calling `PenSyncController` directly from the menu would bypass the observation handoff and could leave two scans competing for the radio.

2. At acceptance, capture Delete, Retain, or Pause as the authorization for that attempt. Give the controller a distinct requested-read entry point: Delete uses the same saved-mode authorization and evidence gates as an automatic read; Retain and Pause explicitly request an ordinary read. Keep `readPenData()` and its per-read confirmation behavior for the headless acceptance runner. The paused command does not temporarily switch preferences to Retain, because that would resume discovery, write a misleading saved mode, and require restoring it after failures.

3. Start the attempt immediately, even if the observer has not seen a pen. The existing bounded selection scan reports a missing pen or asks the user to choose among multiple matches. After acceptance, set the coordinator's last-attempt time to the manual start so the next automatic interval does not immediately duplicate the read. During Pause, no timer or observation starts after completion; changing the mode later resumes the existing schedule. A mode changed during the read affects only later attempts.

4. Reuse the controller's current outcome and cleanup reporting. A Delete request can send a deleting transfer only with requested export, version-matched evidence, matching pen identity, and durable packet storage. Each acknowledged packet must be committed before acknowledgement; the existing journaled deletion state remains prepared -> requested -> confirmed and uncertain outcomes remain reported as such. The fallback is an ordinary read and sends no later separate deletion command. Retain and Pause never request a deleting option. The portable `PenTransport` and fixture-backed Linux tests remain separate from `CoreBluetoothPenTransport` in the Mac app. Page keys remain `(section, owner, book, page)` with SHA-256 stroke fingerprints; committed library rows feed deterministic JSON, SVG, and Markdown publication through atomic sibling-temp renames. The menu change adds no Apple import to portable packages.

## Risks / Trade-offs

- A manual click can race an advertisement or interval tick -> serialize both through the coordinator and test one attempt for the race.
- Pause visually indicates no automatic read, yet Sync Now can run -> keep Pause checked and show Syncing during the one-time attempt; return to Paused if the user has not selected another mode.
- The active `simplify-menu-sync-actions` delta restricts Pause's scheduling behavior -> keep its wording scoped to automatic discovery and reads so the explicit one-time retaining command remains possible.
- Delete sounds unconditional -> keep the existing gate and accurate skipped, partial, and confirmed outcomes in Connection Details.

## Migration Plan

No data migration is needed. Add the coordinator request path and menu command together; existing saved mode and interval keys keep their values. Rollback removes the command and request path without changing stored strokes or preferences. Verify with fake-clock and fake-transport tests on Linux, the full Xcode-gated Mac build, and a physical A1 read before recording any new deletion acceptance claim.
