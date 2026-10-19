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

## Pen retention

`PenCleanupPolicy.mode` defaults to `keepOnPen`, and
`PenCleanupPolicy.deletionEnabled` is `false` for every policy this build can
construct. A `keepOnPen` import writes no cleanup journal row at all. A policy
that asks for deletion records `prepared` and stops there: `requested` is never
recorded and no deletion command exists in the session, so the pen always keeps
its copy. Physical A1 acceptance must pass before a later change enables cleanup.

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
batch progress across a reopen, the cleanup journal, and the importer's save,
export-failure, retry, and restart paths.
