# Proposal

## Why

Every sync re-transfers the whole note even when nothing is new: a read of note
700 returned all 8062 strokes, of which 0 were new, and re-sent 1.4 MB the
library already held. Meanwhile the pen's storage is finite, and the cleanup
policy is stubbed so that deletion can never be enabled — `deletionEnabled` is a
hardcoded `false` — leaving a user who does not want data accumulating on the
pen with no path to that outcome.

Both questions rest on the same evidence: what each `0x23` transfer option
actually does to the pen's cursor and to its stored data. Settle that once, and
both the transfer request shape and the deletion trigger follow from it.

## What Changes

- Choose the `0x23` transfer option from a physical A1 trace instead of inheriting
  it from the SDK sample, and record what every `OfflineTransferOption` value does
  to the pen's cursor and stored data.
- Pin the transfer option that avoids re-sending stored strokes, if the trace shows
  one exists, with tests that fix the request bytes.
- Exclude any transfer option that deletes during transfer from the read path.
  Deletion travels on the acknowledged path, not the transfer.
- Make cleanup the normal outcome of a sync after a complete transfer, durable
  import, and successful publication of every requested export. Keep retention
  available as a choice.
- Replace the permanent prohibition on `0x25`/`0x27` with an evidence gate: the
  commands may be sent only when traces establish safe payload framing, deletion
  scope limited to verified data, acknowledgement meaning, and retention after an
  interrupted transfer. If any condition is unmet, retain the pen's copy and
  report why cleanup was skipped.
- Define the cleanup policy in the portable domain: the two modes, the default, and
  the durable `prepared → requested → confirmed` journal that a crash mid-delete
  needs.
- Reconcile an outstanding deletion after a crash by re-reading and comparing the
  pen's remaining data with the durable library. Never blindly resend it.

## Capabilities

### New Capabilities

None. Every behavior this change alters already belongs to a capability.

### Modified Capabilities

- `pen-session`: the offline retrieval requirement gains the transfer option and its
  evidence basis, and the permanent prohibition on deletion becomes an ordering
  requirement — deletion only after confirmed storage.
- `portable-pen-domain`: adds the cleanup policy, its default, and the durable states
  a deletion request passes through.
- `stroke-library`: safe pen retention becomes conditional — cleanup follows a
  complete verified import and successful exports when the evidence gate permits it.
- `macos-app-shell`: presents default cleanup, an explicit retention choice, and
  the reason when cleanup is skipped or remains outstanding.

## Impact

- `Packages/NeoProtocol`: `PenRequest.offlineData`, `PenSession`, and the two
  `OfflineTransferOption` values the session may send; `CommandEvidence` moves
  `0x25`/`0x27` from blocked to gated.
- `Packages/NeoCore`: `PenCleanupPolicy` and the `deletionEnabled` gate, plus
  `PenCleanupState` and `PenCleanupJournal`.
- `Packages/NeoStorage`: `PenLibraryImporter.acknowledge`, which currently records
  `.prepared` and sends nothing.
- `Apps/NeoBridgeMac`: the menu and details window show the default cleanup
  outcome, offer retention, and report skipped or outstanding cleanup.
- `Tests/Hardware` and `docs/protocol-a1.md`: the trace evidence and acceptance rows
  for the transfer options and for deletion.
- Ordering: this change modifies `stroke-library`, which the in-flight
  `add-persistence-and-deterministic-export` introduces. Apply it after that change
  is archived. No new dependencies are required.
