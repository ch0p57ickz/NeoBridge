# Design

## Context

See `proposal.md` for why. The current state that shapes the approach:

- `PenRequest.offlineData(for:)` sends `nextAndReserve` with no compression and a
  zero page count. The value is inherited from the SDK sample rather than from a
  trace of this pen, and both physical reads so far re-transferred everything: the
  2026-10-19 read returned all 8062 strokes, 0 of them new.
- `PenCleanupPolicy.deletionEnabled` is a hardcoded `false`, so
  `PenCleanupMode.deleteAfterAcknowledge` records `.prepared` in the journal and
  sends nothing. `PenCleanupState` already models `prepared`, `requested`, and
  `confirmed`.
- `CommandEvidence` classifies `0x25` and `0x27` as `.officialSDK` for their
  identifiers, from `NISDK3/Classes/Model/CMD.swift`. No A1 trace exists for their
  payload framing or for the `0xA5`/`0xA7` responses, and the evidence table
  currently blocks both commands.
- `PenLibraryImporter.acknowledge` refuses a batch that is not `.published`, which is
  the natural place to hang the ordering rule.

## Goals / Non-Goals

**Goals:**

- Make the pen's transfer behavior a measured fact rather than an inherited default.
- Let a user stop accumulating data on the pen without ever risking the only copy of
  their handwriting.
- Keep every new behavior testable on Linux against a fake transport.

**Non-Goals:**

- Changing what a page or a stroke identity is. Page keys and fingerprints stay as
  they are.
- Cloud, OCR, or multi-pen work.
- Deleting from the pen anything the host has not already stored durably.
- Choosing the winning transfer option in this document. The experiment decides it;
  these requirements hold either way.

## Decisions

### Delete on an acknowledged command after confirmed storage, not on the transfer

`nextAndDelete` makes the pen delete as part of the transfer it is already
performing. At that moment the host holds the bytes in memory and has committed
nothing, so a crash or a failed commit between the final `0xA4` Stop and the library
commit loses the pen's copy with no second source. The user's requirement is "delete
after confirmed sync", which is the opposite ordering.

**Chosen:** send an evidence-backed `0x25`/`0x27` command only for data covered by
a complete transfer, after its import has committed and every export requested for
that data has published successfully. The window in which a failure can cost data shrinks from
"after the transfer" to "after a verified store".

**Alternative rejected:** `nextAndDelete` for its one-byte cost. Cheaper to build,
but it cannot be ordered after storage, so it contradicts the requirement. It is also
excluded by the spec, which forbids any transfer option that deletes, so the
experiment cannot accidentally adopt it.

### The transfer option is decided by an experiment, bounded by the spec

`OfflineTransferOption` documents `notNextTransfer` as "leave the note's data
untouched" and `nextAndReserve` as "keep the note's data so a later read still finds
it". The naming hints at a cursor, but the observed behavior contradicts that: a
`nextAndReserve` read returned every stroke again. Which value yields an incremental
transfer is unknown and cannot be settled by reading the SDK.

**Chosen:** establish a known set of existing strokes, add known new strokes, and
read the note with each candidate option. For each option, compare the returned
stroke identities against both sets, repeat a complete read, and disconnect during
a separate read before its final packet. A fresh read after disconnection must
still recover every expected stroke. Record the request bytes, final packet,
acknowledgements, counts, and identities. Adopt an incremental option only if it
returns exactly the expected new strokes without making any stroke inaccessible.
If no incremental option meets that test, retain the current option only if its
non-destructive behavior is established; otherwise report offline retrieval as
unsupported rather than guessing.

**Alternative rejected:** reasoning from the enum names. Cheap, and wrong often
enough here — the 2.54 mm coordinate guess survived several rounds on that basis.

### The evidence gate becomes data, not a constant

`deletionEnabled` is a literal `false`, so opening the gate means editing a boolean,
which is exactly the kind of change that gets made without the evidence.

**Chosen:** derive the gate from an explicit safe verdict backed by physical A1
traces. A complete transfer requires the final `0x24` end-position packet and its
outbound `0xA4` Stop; the host must also validate and durably commit the
transfer before cleanup. Traces must establish the deletion command payload and
scope, show that it can delete only the exact verified data (including when newer
strokes exist on the same page or note), establish what `0xA5`/`0xA7` confirms,
and show that a disconnected transfer leaves all not-yet-imported strokes
retrievable. A trace's mere existence, or a trace showing unsafe behavior, does
not open the gate. If either deletion command cannot be safely scoped, that
command remains disabled.

**Alternative considered:** keep the constant and flip it in the change that lands
the trace. Simpler, but it separates the gate from its evidence and makes the gate
easy to reopen by mistake.

### Cleanup is the default when proven safe

The user wants completed syncs to reclaim pen storage without repeatedly choosing
cleanup. Retention remains an explicit choice for a sync.

**Chosen:** each sync starts with cleanup as its intended mode. The app shows this
before transfer and offers retention. The evidence gate, transfer completion,
durable import, and successful exports decide whether cleanup can actually run.
When any condition fails, the pen retains the data and the app reports why. A
retention choice applies to that sync only; no stale choice is inherited.

**Alternative rejected:** requiring an affirmative deletion choice every sync.
That leaves pen storage accumulating when the user forgets the choice.

### The journal stays, and the state machine is unchanged

`prepared → requested → confirmed` fits the ordering rule. A crash can leave an
outstanding request whose effect is unknown. Re-importing the same strokes is safe
for library deduplication, but it does not prove whether deletion happened.

**Chosen:** keep the three states and the existing `acknowledge` guard, which already
refuses a batch that is not published. Record the exact deletion scope before
sending, mark it requested before bytes can reach the pen, and promote it to
confirmed only when a trace establishes that the matching response proves that
scope was removed. After a crash or timeout, re-read and compare remaining pen
data with the durable library. Resolve the outstanding request only when the
observed result and proven command scope make the outcome unambiguous. Otherwise
leave it outstanding and do not resend automatically.

### Completed notes can be cleaned up independently

A later note can fail after an earlier note has completed. The overall sync remains
incomplete, but an earlier note can be cleaned up if its own transfer, import, and
requested exports succeeded and the deletion command targets only its verified
data. A failed note and any overlapping deletion scope remain on the pen.

### Layering

`PenSession` puts the bytes on the wire, so it owns the ordering requirement and is
testable against `FakePenTransport`. It takes an explicit deletion request; it never
originates one. `PenCleanupPolicy`, `PenCleanupState`, and `PenCleanupJournal` stay in
NeoCore, and the SQLite journal stays in NeoStorage, so the portability boundary is
untouched: no new Apple import appears in any package.

## Risks / Trade-offs

- [A command removes newer or unverified strokes on a stored page] → The command
  stays disabled until a physical trace proves its scope excludes those strokes.
- [The experiment shows no incremental mode] → Use the current option only if its
  non-destructive behavior is proven, and record that incremental transfer is not
  available. Otherwise stop offline retrieval.
- [The `0x25`/`0x27` payload framing is wrong on the A1] → The gate stays closed until
  a trace establishes it, so a wrong guess cannot reach a pen holding the user's only
  copy.
- [An interrupted transfer is shown to delete data] → No traceable behavior exists to
  depend on, so the change must not enable deletion at all; if that happens, the gate
  stays shut and the finding drives a narrower design.
- [The user deletes from the pen and then loses the library] → Out of scope for the
  specs, but the change depends on a recovery story existing before the gate opens;
  the library copy is never deleted, and exports remain the user-visible duplicate.

## Migration Plan

1. Land the experiment and its evidence records first. No behavior changes.
2. Adopt the transfer option the experiment supports, with tests pinning the bytes.
3. Build the deletion path behind the closed gate, with the journal wired up and the
   UI showing the mode. Deletion remains unreachable.
4. Record the traces the gate requires. Opening the gate is then a data change, not a
   code edit.
5. Rollback: close the evidence gate to retain pen data on future syncs. Pen data
   already deleted cannot be restored by a mode change; the durable library and
   successfully published exports remain the recovery copies.

**Dependency:** this change modifies the `stroke-library` capability, which the
in-flight `add-persistence-and-deterministic-export` introduces. Archive that change
first, or validation reports the target spec as missing.

## Open Questions

- Which non-destructive transfer option, if any, yields an incremental read. The
  experiment answers it without changing these specs, tasks, or the approach.
- Whether `0x25` scopes to a note and `0x27` to a page, or whether both take a page
  range. The trace settles it, and both are gated identically.
- Whether a deletion acknowledgement proves removal of the requested scope or only
  acceptance of the command. Until a physical trace settles this, the request stays
  outstanding and the gate stays closed.
