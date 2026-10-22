# Proposal

## Why

Repeated syncs add strokes to pages already held in the SQLite library, but the current exporter backs up every changed JSON, SVG, and Markdown file. Ordinary page growth therefore fills the export folder with redundant copies.

## What Changes

- Keep SQLite as the source of truth. Export the complete stored page as one deterministic JSON document; a later pen read adds to the stored page even if the pen deleted its earlier copy.
- Back up an existing JSON only when it contains data absent from the new export, has a different page identity, or cannot be understood safely. Preserve it, then atomically replace it with the SQLite-derived JSON. Keep the bounded three-version JSON history.
- Replace changed SVG and Markdown outputs atomically without creating backups. Both are generated from the page data and export rules.
- Keep identical targets untouched and continue reporting publication results for each file. No recovery or merge from an older JSON into SQLite is required.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `page-export`: Change the backup rule by format and distinguish ordinary page growth from conflicting existing JSON data.

## Impact

The change affects `Packages/NeoExport` publication logic and tests, plus the `page-export` specification and export documentation. Portable tests run on Linux; the Mac build remains a separate verification gate. It does not alter A1 protocol behavior or the physical M0 evidence gate for pen operations.
