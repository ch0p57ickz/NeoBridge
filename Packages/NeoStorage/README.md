# NeoStorage

Durable, portable storage for NeoBridge: canonical Ncode pages, replay-safe
strokes, import batch progress, and the dormant pen cleanup journal. The package
is portable Swift: it builds and passes `swift test` on Linux and macOS, and it
imports no Apple-only framework.

## What it provides

| Type | Role |
| --- | --- |
| `SQLitePenLibrary` | The library: one SQLite connection in WAL mode, serialized by an actor |
| `PenLibraryImporter` | The verified importer: collect, validate, commit, publish |
| `StorageError` | Every failure the layer reports |

`SQLitePenLibrary` implements `PenStrokeStore`, `PenImportBatchStore`, and
`PenCleanupJournal` from `NeoCore`. `PenLibraryImporter` implements
`PenImportCoordinator`.

## Database location

The package takes a path; the app chooses it. NeoBridge uses

```text
~/Library/Application Support/NeoBridge/library.sqlite
```

and lets the system create the directory. Tests and other callers pass a
temporary path or `:memory:` for a throwaway library.

The database is a single file with two siblings the write-ahead log creates and
removes as it works: `library.sqlite-wal` and `library.sqlite-shm`. All three
belong to the library; copying the file while the app runs needs all of them. A
schema upgrade writes one more file beside them, a pre-migration backup named
`library.sqlite.backup-v<version>`, which holds the database as it was before the
upgrade. The library leaves that backup in place; it is replaced only when a later
open has to migrate the same file again, and the replacement is written under a
temporary name and moved into place only once it verifies.

## Schema

The schema version is recorded in `metadata.schema_version`, and
`SQLitePenLibrary.schemaVersion` is the version this build writes.

| Table | Holds |
| --- | --- |
| `metadata` | The schema version |
| `pages` | One row per `(section, owner, book, page)`, unique on all four |
| `strokes` | One row per stored stroke: its page, encoding version, fingerprint, deduplication flag, origin reliability and reported time, source, and canonical bytes |
| `points` | One row per point, keyed by `(stroke_id, ordinal)` so point order is exact |
| `batches` | Import progress: state, counts, an insertion ordinal, the transfer kind (`ordinary` or `deleting`), the completion (`inProgress`, `partial`, or `complete`), and how many packets were durably committed |
| `batch_pages` | The pages a batch's strokes belong to, so publication can be retried |
| `batch_packets` | One row per durably committed packet of a deleting transfer, in commit order |
| `cleanup_journal` | Append-only cleanup states per batch |
| `cleanup_requests` | The exact scope of a cleanup request: its batch, proven command, and pages |

A stroke's identity is the SHA-256 digest of its canonical encoding: the page
tuple, the pen-origin time and its reliability, and the ordered points. Host
arrival time, source, and transport chunking are excluded.

`strokes_reliable_fingerprint` is a **partial** unique index over
`fingerprint` where `allows_cross_source_deduplication = 1`. A reliable stroke is
therefore stored once however often it is replayed, while a stroke whose origin
time is not reliable keeps its own row, so two different marks that share a digest
do not collapse into one.

### Migration behavior

On open, the library reads the version the file records, if it records one, and
then verifies the file's actual shape rather than trusting that version.

- No version and no library tables: a new file. The schema is created and stamped
  with the current version, and no backup is written, because there is nothing to
  copy.
- Version older than the build, or a file that holds the old tables with no version
  row: the upgrade is additive. It is preceded by a SQLite-consistent backup beside
  the database, named `<database>.backup-v<version>`. The copy is built under a
  temporary name and given that name only after it has been reopened read-only and its
  version read back, so a partial or rejected copy never sits where the next open
  would read it, and it is written `0o600` — stricter than the library file it copies,
  which SQLite creates with the process umask. The added columns carry defaults, so a
  legacy batch reads as an ordinary, complete read with no durable packets. The
  version is then stamped with the current one.
- A version row that is not a number: the library refuses to open with
  `StorageError.unreadableSchemaVersion`. Reading it as an older file would migrate
  a schema this build cannot identify.
- Version newer than the build: the library refuses to open with
  `StorageError.unsupportedSchemaVersion`. The file is left untouched, because a
  newer file may hold columns this build would drop.
- A file that recorded the current version without the columns the version implies:
  the columns are added and the file is backed up like any other legacy file, so a
  half-written record is repaired instead of being reported ready and then failing
  on the first batch read.

If backup creation or its read-back fails, the original is left untouched, the
upgrade is abandoned, `PenLibraryOpenReport.deletingReadsAllowed` is `false`, and
the report names the file and the failure. In-memory libraries take no backup,
because they have no file to copy.

WAL mode, foreign keys, and `synchronous = FULL` are set on every connection, so a
committed batch survives a power loss without a repair step.

## Recovery

The import lifecycle is durable at every step, so a restart is recoverable without
guessing:

| State on restart | What happens |
| --- | --- |
| `collecting` or `validated` | The in-memory buffer is gone. A `collecting` batch never reached a commit. A `validated` batch may have stored its strokes just before a crash between the insert and the commit marker; re-reading the pen is safe because reliable strokes deduplicate. Committing the batch fails with `StorageError.collectedStrokesUnavailable`. |
| `committed` | The strokes are stored. Publication is retried with `retryExport(batchID:request:)`, which re-reads the stored rows. |
| `published` | The read is stored and its files were written. Re-publishing is still allowed. |
| `failed` | The commit failed and the whole transaction was rolled back, so the library holds no partial batch. |

A commit is one transaction: either every stroke of the read is stored or none is.
A publication is one file at a time: a failure leaves the committed strokes in
place and reports each file's own outcome, so a retry finishes the set without
importing the read again.

A deleting transfer is durable packet by packet rather than at the end. Its batch
is recorded as `committed` and `inProgress` before the first `0x23` packet, and each
acknowledged packet's strokes and progress are committed in one flushed transaction
before that packet's acknowledgement. A restart therefore reads the acknowledged
prefix from `batch_packets` instead of guessing: the batch stays `inProgress` or
`partial`, its committed pages remain exportable, and a fresh read starts a new
batch for the remainder. Reliable-stroke fingerprints deduplicate what the fresh
read replays, so a packet the pen never had acknowledged is not stored twice.

## Pen cleanup

The pen's copy is reclaimed by one of two routes, and they have different rules.

A **deleting transfer** removes each packet from the pen as the transfer that reads
it runs, so its bound is the acknowledgement rather than a command: the library
commits a packet before the session acknowledges it, and `beginDeletingRead`,
`commitDeletingPacket`, `finishDeletingRead`, and `failDeletingRead` are the barrier
that enforces the order. Nothing is asked of the pen for a packet that was not
committed first. `requestCleanup` refuses every deleting batch, including a
`published + complete` one, because the transfer already removed what it stored.

A read that ends before its first durable packet — a dropped link, a refused or
malformed response, a failed first commit, or a cancellation — has no prefix to
report and nothing to publish, so the session marks the batch it opened failed
rather than leaving it in progress. `failDeletingRead` writes that state only for a
deleting batch that is still `inProgress` with no packet, so an ordinary batch, a
batch with a durable prefix, and a finished batch are untouched. The row is kept,
because it is the durable record that the read was attempted.

A separate **`0x25`/`0x27` deletion command** is requested independently of the
import, by `PenLibraryImporter.requestCleanup(_:request:)`, so it can be ordered
after it. The ordering rule is what makes it safe: the pen's copy is reclaimed only
for data whose complete transfer has committed durably **and** for which an export
published in full. A batch that is not `published` is refused, so a read whose
publication failed, was left partial, or was never requested keeps its pen copy:
with nothing published, the library copy is the read's only copy, and the reason
says so. A scope that shares a page with a batch that has not published is refused
too, so a completed note is reclaimed only on its own pages and a later failed note
keeps its strokes on the pen. A batch with a completion other than `complete` is
treated as incomplete even when it is `published`, so a partial deleting batch
blocks a shared page from this route as well.

The request is journaled in three states:

| State | Written when | Meaning |
| --- | --- | --- |
| `prepared` | the exact scope is known, before anything can be sent | the scope is durable, so a restart can compare it with a fresh read |
| `requested` | before the bytes can reach the pen | a deletion may have been sent; the effect is unknown |
| `confirmed` | an evidence-backed response proves the recorded scope was removed | the pen's copy is gone |

`cleanup_requests` holds the scope itself — the batch, the proven command, and the
pages — so a request can be compared with a later read instead of repeated.

The journal is terminal in both directions: a `requested` request is never resent
automatically, and a `confirmed` one is never sent again. `resolveCleanup(_:storedPages:)`
is the only thing that may resolve an outstanding request, it never deletes, and it
reads the pages from the durable record rather than from its caller. It requires the
pen's whole stored-page inventory: `storedPages: nil` means the read did not finish
or did not cover the whole pen, which is also what a read that returns only new data
passes, so removal is not proven and the request stays outstanding. Only when every
recorded page is absent from an inventory of the whole pen is the request confirmed.

One batch has at most one request in flight: a second `requestCleanup` for a batch
that is already between its checks and its send is reported as outstanding rather
than sending the command again, because the journal's own states cannot close that
window. A request whose task is cancelled before the command is sent is recorded and
left outstanding, so a sync the user ended puts nothing on the wire.

A journal write that fails after the pen confirmed removal does not change the
reported outcome: the read is reported reclaimed, because the removal happened. The
unrecorded confirmation leaves the request outstanding, which is the state a crash
between the send and the write leaves, so a later read resolves it by comparing the
recorded scope with the pen's inventory instead of resending the command.

A journal row this build cannot decode is refused rather than read as an absent
request: `latestState(batchID:)` and `recordedScope(batchID:)` throw
`StorageError.unreadableCleanupState` or `.unreadableCleanupScope`, and the cleanup
path reports the outcome as outstanding, because a row that cannot be read says
nothing about whether a deletion was already sent. A state that names a request
whose scope is missing, or a confirmation whose scope is missing, is treated the
same way: the removal is not proven and the request is not repeated.

A read with no stored page is refused too, so an empty scope is never journaled and
never sent.

A read whose export was never requested stays `committed`, so it is not reclaimable
either: cleanup requires an export that published in full, and a read with none
retains the pen's copy with a reason that names the batch's state and says the
library copy is the read's only copy.

`PenCleanupPolicy.mode` defaults to `deleteAfterAcknowledge`, which is an intent,
not permission. The two routes derive permission from two separate records.
`PenCleanupPolicy.deletionEnabled` derives from `PenDeletionEvidence`, and the
record this build carries is the physical A1 trace of 2026-10-20, which settles
three conditions and records the deletion scope as `unsafe`, so no `0x25`/`0x27`
deletion command can be sent. The deleting transfer derives from
`PenDeletingTransferEvidence`, built from the 2026-10-21 runs, and needs a
requested export, a per-sync confirmation, and durable packet storage on top of it.
A later change records the safe verdicts that would open the command gate, and only
a scope a trace proves can supply them.

## Building and testing

The package needs SQLite headers at build time.

- macOS: the header and library ship with the SDK, so nothing extra is needed.
- Debian/Ubuntu: install the development package.

```bash
sudo apt-get install -y libsqlite3-dev
```

Then:

```bash
cd Packages/NeoStorage
swift test
```

`Scripts/test-portable.sh` runs this package with the rest and checks for the
SQLite header first, so a missing prerequisite is reported with that install hint
rather than as a compile error.

The test suites cover round trips, canonical page identity, deduplication of
replayed and unreliable strokes, rollback of a failed batch, schema refusal,
batch progress across a reopen, the cleanup journal and its recorded scopes, and
the importer's save, export-failure, retry, restart, and cleanup-ordering paths.
