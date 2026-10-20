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

The database is a single file with three siblings the write-ahead log creates and
removes as it works: `library.sqlite-wal`, `library.sqlite-shm`. All four belong
to the library; copying the file while the app runs needs all of them.

## Schema

The schema version is recorded in `metadata.schema_version`, and
`SQLitePenLibrary.schemaVersion` is the version this build writes.

| Table | Holds |
| --- | --- |
| `metadata` | The schema version |
| `pages` | One row per `(section, owner, book, page)`, unique on all four |
| `strokes` | One row per stored stroke: its page, encoding version, fingerprint, deduplication flag, origin reliability and reported time, source, and canonical bytes |
| `points` | One row per point, keyed by `(stroke_id, ordinal)` so point order is exact |
| `batches` | Import progress: state, counts, and an insertion ordinal |
| `batch_pages` | The pages a batch's strokes belong to, so publication can be retried |
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

On open, the library creates any missing table and reads `metadata.schema_version`.

- No version recorded: the schema is created and stamped with the current version.
- Version older than the build: this build has no older schema to migrate from yet,
  so the tables are created if missing and the version stays as recorded until a
  migration exists.
- Version newer than the build: the library refuses to open with
  `StorageError.unsupportedSchemaVersion`. The file is left untouched, because a
  newer file may hold columns this build would drop.

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

## Pen cleanup

Cleanup is requested separately from the import, by
`PenLibraryImporter.requestCleanup(_:request:)`, so it can be ordered after it.
The ordering rule is what makes it safe: the pen's copy is reclaimed only for data
whose complete transfer has committed durably **and** for which an export published
in full. A batch that is not `published` is refused, so a read whose publication
failed, was left partial, or was never requested keeps its pen copy: with nothing
published, the library copy is the read's only copy, and the reason says so. A scope
that shares a page with a batch that has not published is refused too, so a
completed note is reclaimed only on its own pages and a later failed note keeps its
strokes on the pen.

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
not permission. `PenCleanupPolicy.deletionEnabled` derives from
`PenDeletionEvidence`, and the evidence record holds a `pending` verdict for every
condition until a physical A1 trace establishes it, so no deletion command can be
sent by this build. Physical A1 acceptance must pass before a later change records
the safe verdicts that open the gate.

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
