# Tasks

## 1. JSON conflict classification

- [x] 1.1 Add strict version-1 JSON page validation and comparison in `Packages/NeoExport` that checks identity and full stroke-record multiplicity; verify tests distinguish ordinary growth, removed or replaced strokes, lost duplicates, formatting differences, malformed JSON, unsupported versions, and missing, unknown, or duplicate fields.
- [x] 1.2 Pass the comparison result into file publication so a conflicting JSON preserves its prior bytes before atomic replacement while ordinary growth does not; verify bounded rotation and preservation-failure tests leave a conflicting target unchanged on failure.

## 2. Generated output publication

- [x] 2.1 Replace changed SVG and Markdown files atomically without backups while retaining identical-file and symlink behavior; verify publication tests cover changed and unchanged files and per-file failure reports.
- [x] 2.2 Update `Packages/NeoExport/README.md` to explain SQLite authority, complete-page JSON replacement, conflict-only JSON history, generated SVG/Markdown replacement, and treatment of existing backups; verify the examples agree with the tests.

## 3. Integration verification

- [x] 3.1 Add or extend a portable importer/export integration test showing that a later sync for a page retains earlier SQLite strokes in the replacement JSON without a backup, and that a smaller SQLite page preserves the older JSON before replacement; verify the relevant `NeoStorage` tests pass.
- [x] 3.2 Run `Scripts/test-portable.sh` and `Scripts/remote-mac-build.sh`; record the results in `docs/portable-verification.md`, and leave any unavailable Mac or physical-hardware gate explicitly incomplete rather than claiming it passed.
