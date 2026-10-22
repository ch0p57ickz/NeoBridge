# Proposal

## Why

NeoBridge can save offline strokes but cannot reclaim pen storage: the `0x25` command removes an entire note, including data outside the verified read, and `0x27` is refused. A physical A1 trace on 2026-10-21 instead shows that `0x23` option `0x01` removes only an acknowledged packet prefix, making a durable commit before each acknowledgement a viable deletion boundary.

## What Changes

- Add a deleting offline read using the SDK's `NextAndDelete` (`0x01`) transfer option under one data-driven cleanup authorization policy with an evidence record per route. Keep the existing `0x25`/`0x27` command record closed, including its `unsafe` deletion-scope verdict.
- Commit and flush every accepted packet's complete strokes and recovery state before sending its `0xA4` acknowledgement, including the final Stop. On failure, preserve committed strokes, leave the unacknowledged remainder retrievable, and retry through a fresh read with replay deduplication.
- Record partial deleting reads and their export status honestly. A durable library copy can be published or re-exported even when the transfer, an export, or a later note fails.
- Require a requested export and keep the cleanup choice explicit, confirmed, and limited to one sync. A no-export sync uses a non-destructive read. Explain before a deleting transfer that acknowledged data leaves the pen as the read progresses, before file export is complete.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pen-session`: Admit only an explicitly authorized deleting transfer and order packet acknowledgement after durable storage.
- `portable-pen-domain`: Distinguish the transfer-option evidence gate and progress from the still-closed command deletion journal.
- `stroke-library`: Persist acknowledged packets and partial batches, with recovery and re-export semantics.
- `macos-app-shell`: Present the per-sync consent, early removal risk, partial result, and recovery options accurately.
- `protocol-fixture-testing`: Verify the transfer option, packet pacing, and failure boundaries with sanitized evidence and fake transport.

## Impact

The change spans portable NeoProtocol, NeoCore, NeoStorage, the macOS runner and shell, and integration fixtures. It uses the existing SQLite WAL library, canonical page tuple, SHA-256 stroke fingerprint, and deterministic JSON/SVG/Markdown export pipeline; no cloud service or new store is added. The M0 protocol gate is the official SDK option definition plus the physical A1 evidence in `docs/protocol-a1.md` ("Deleting transfer option, 2026-10-21") and the committed paired fixtures under `Tests/Fixtures/deleting-transfer/`, which are sanitized from the 2026-10-21 raw runs (uncommitted and git-ignored). The re-run measured zero removal without an acknowledgement and exactly 13 removed strokes after acknowledging a 13-stroke packet; the pen's internal removal trigger remains unknown. Portable verification runs on Linux; app build and physical acceptance require the Mac runner. This proposal does not authorize new pen experiments. The deleting route is active for the traced identity when this change ships: the Mac runner's Xcode gate and the physical A1 acceptance run verify the enabled route rather than hold it back, and the fact that no run has yet exercised the app's own deleting read against a pen is recorded as a known gap in the design's risks.
