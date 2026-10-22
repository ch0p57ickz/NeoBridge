# NeoExport

Deterministic, portable page export for NeoBridge. Every non-empty page is written
as one JSON record, one SVG drawing, and one Markdown page. The package is
portable Swift: it builds and passes `swift test` on Linux and macOS, and it
imports no Apple-only framework.

## What it provides

| Type | Role |
| --- | --- |
| `PageExportDocument` | One page's strokes in canonical order, plus its file names |
| `PageCanvas` | The fixed page canvas every SVG drawing is placed on |
| `JSONPageRenderer`, `SVGPageRenderer`, `MarkdownPageRenderer` | The three renderers |
| `FilePenExportPublisher` | Publishes the three files for every page |
| `ExportNumberFormat`, `ExportEscaping` | Fixed number formatting and XML/Markdown escaping |

`FilePenExportPublisher` implements `PenExportPublisher` from `NeoCore`. It never
throws for a per-file problem: it returns one `PenExportArtifact` per requested
target, so the caller can see which files were written, which were already
correct, and which failed.

## Determinism

For the same page and stroke multiset, the same format version produces
byte-identical files, whatever the import order, the process, or the source was.

- Strokes are sorted by their **canonical encoding bytes**, not by row identifier
  or arrival order.
- Two strokes with identical canonical bytes are adjacent and render identically,
  so a page that retains several identical unreliable strokes keeps every
  occurrence without an unstable tie-breaker.
- Source, host timestamps, storage identifiers, batch identifiers, and device
  identifiers are never written.
- Numbers are formatted with integer arithmetic, so no locale or rounding mode can
  change the bytes.
- Files are UTF-8 with Unix newlines and exactly one trailing newline.

## Output schema

### JSON (`ncode-s<section>-o<owner>-b<book>-p<page>.json`)

The layout is versioned by `formatVersion` and written by hand, because the field
order has to be fixed for byte-for-byte reproducibility.

```json
{
  "formatVersion": 1,
  "section": 3,
  "owner": 27,
  "book": 700,
  "page": 1,
  "strokes": [
    {
      "originTimeReliable": true,
      "originTimeMilliseconds": 1700000000000,
      "points": [
        { "x": -12345, "y": 67890, "penTimeOffsetMilliseconds": 0, "pressure": 12 }
      ]
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `formatVersion` | The layout version, currently 1 |
| `section`, `owner`, `book`, `page` | The four canonical page components |
| `originTimeReliable` | Whether the pen-origin start time may be trusted |
| `originTimeMilliseconds` | The reported pen-origin time, or `null` when the pen reported none |
| `x`, `y` | Coordinates in hundredths of a pen unit |
| `penTimeOffsetMilliseconds` | Milliseconds from the stroke's origin time |
| `pressure` | The raw pen pressure reading |

### SVG (`ncode-s<section>-o<owner>-b<book>-p<page>.svg`)

The drawing carries the same sorted strokes. Every page is drawn on the same
canvas, so the pages of a note share one scale and one origin and can be compared
or overlaid.

- The canvas is the notebook sheet, `0 0 54.84 88.58` in pen coordinate units.
  The sheet is 130 x 210 mm, and the pen's coordinate unit is 6.72 NCode project
  points, which is 2.3707 mm.
- The canvas is emitted in millimetres as well, so the file prints at its true
  size.
- The stroke width is 0.15 units, which is the one-point line the Neo iOS SDK's
  own stroke renderer draws.
- A page whose ink reaches past the sheet's right or bottom edge grows the canvas
  rather than clipping the stroke. The origin stays at `0 0`, because a moving
  origin would stop two pages of a note from lining up. Ink past the left or top
  edge would therefore fall outside the canvas, which a real read cannot produce:
  the wire format carries a `UInt16` integer part, so a coordinate is never
  negative.
- Every coordinate is written with exactly two decimals, and every text node and
  attribute is XML-escaped.

Deriving the canvas from each page's own ink, which is what an earlier version
did, gave every page a different scale and origin and drew the ink at the size of
the writing, which is unreadable for a line of text.

### Markdown (`ncode-s<section>-o<owner>-b<book>-p<page>.md`)

The page lists the four components, the format version, the stroke and dot
counts, and relative links to the matching `.json` and `.svg` files. Text is
Markdown-escaped, so a value can never be read as markup.

A page with no stored stroke produces no files at all, in any format.

## File publication

The stored library is the source of truth for every exported file. Each export
renders the page's **complete** stored stroke set — never only the strokes one read
delivered, and never text appended to a previous file — and replaces the target
atomically. `FilePenExportPublisher` writes each target in this order:

1. **Refuse links.** A target that is a symbolic link is refused and reported.
   Nothing outside the chosen folder is ever written.
2. **Compare bytes.** A target that already holds exactly the generated bytes is
   left alone and gets no backup.
3. **Decide.** What happens to the prior bytes when they differ follows from what
   the format means; see *Backups by format* below.
4. **Clean up.** Temporary files a previous interrupted run left beside this target
   are removed.
5. **Preserve.** When the decision says to, the prior bytes are staged in a sibling
   temporary file, verified by reading them back, then filed into the backup
   history. If this fails, the target is left exactly as it was and the failure is
   reported.
6. **Replace.** The new bytes are staged in a sibling temporary file, verified,
   flushed with `fsync`, and renamed over the target. A rename is atomic, so a
   reader never observes a partial file.

Publication success is reported only when every requested target succeeded. An
unchanged target counts as a success, because its content already matches.

### Backups by format

The JSON record is the one file the library cannot always regenerate. A later read
adds strokes to a page the library already holds, but a library that was rebuilt,
or a page that was reset, can leave a record holding strokes the current page no
longer has. A differing JSON target is therefore read back and compared with the
record about to be written:

- The record is validated against the version-1 layout in full: the format version,
  the four page components, and every field of every stroke and point. A member that
  is missing, unknown, or repeated anywhere fails validation, as does a value of
  the wrong type or outside its range.
- If it validates, identifies the same page, and every stroke occurrence it holds —
  counted, so two identical strokes are two — also occurs in the new record, then
  the new record supersedes it and the target is replaced **without** a backup.
  Ordinary page growth, a reordered or reformatted file, and a plain re-export all
  take this path. A stroke is compared by its complete content: its origin time,
  including whether the pen reported one at all — a record that reports nothing is
  not a record that reports zero — and its ordered points.
- Otherwise the prior bytes are preserved at `<target>.json.bak1` before the target
  is replaced with the record derived from the library. Prior file data is never
  merged into the exported record, and no prior file is ever read back into the
  library.

SVG and Markdown are projections of the same page data, so a changed one is
replaced without a backup. A link left at one of their `.bak1` slots by an older
release is not a hazard, because nothing writes there any more, and the export is
not refused for it; a backup file an older release filed there is left exactly as
it is.

### Backup history

Each JSON record keeps at most **three** prior versions, at `<target>.bak1` (most
recent), `.bak2`, and `.bak3`. The newest generated version is always the primary
file; the history holds only records that were replaced, so a folder that is only
re-exported stays free of new `.bak` files.

Files an earlier release created beside SVG and Markdown targets — `.svg.bak*` and
`.md.bak*` — are left exactly as they are and never deleted automatically, because
one of them might hold something the library does not. The `.json.bak*` slots are
not like that: they are this build's live backup history, so filing a new JSON
backup rotates them, shifts each older version up, and drops the oldest, which is
what keeps the history bounded at three.

A crash between formats can leave a page with mixed versions. Every file is a
complete projection of the library, so the fix is to publish the whole set again:
a retry renders the same bytes, leaves the files that already match, and completes
the ones that do not.

### No in-file merge

The library merges replayed pen strokes; the exported files are complete
projections of that library, and no exported file is ever parsed back into it. An
edit inside an SVG or Markdown file is replaced without a backup. An edit inside a
JSON file is kept as a backup unless the edited record still reads as no more than
the page being exported, and is then replaced. In every case the generated file is
derived from the stored strokes alone.

## Building and testing

```bash
cd Packages/NeoExport
swift test
```

The suites cover golden bytes for all three formats, determinism across reordered
input and across sources, retained multiplicity, empty pages, non-colliding file
names for pages that share a page number, escaping, number formatting, atomic
replacement, the strict JSON reader and the record comparison behind the backup
rules, symlink refusal, per-file failure reporting, retry, and orphaned
temporary-file cleanup.
