# Agent instructions for NeoBridge

NeoBridge is a local-first macOS app for the Neo Smartpen A1 / F151. Portable core
logic is written and tested on Linux; Xcode builds and physical-pen acceptance testing
happen on a remote macOS runner.

`openspec/config.yaml` is the authoritative source for project context, package
layout, and the rules for each OpenSpec stage. Read it before proposing or applying a
change. This file covers the operational details that are easy to get wrong.

## Code exploration

Navigate code through the jCodemunch index rather than reading files blindly. The
integration is reached through Rumi, so the call path is `rumi_list_integrations`, then
`rumi_list_tools` for the `jcodemunch` integration, then `rumi_call_tool` with
`tool: "order"` carrying the action.

```text
order { "action": "resolve_repo", "args": { "path": "." } }                     # is this checkout indexed?
order { "action": "index_folder", "args": { "path": "." }, "allow_state_change": true }   # index it once per machine
```

Then call `order` for an action you know, `route` when you know the goal but not the
action, and `menu` to see what exists. `search_symbols`, `search_text`,
`get_file_outline`, `get_file_content`, and `get_file_tree` cover most exploration.
`check_edit_safe` and `check_delete_safe` answer whether a symbol is safe to change
before you change it. State-changing actions need `allow_state_change: true` in the same
`order` arguments.

The index lives on the jCodemunch server, not in this repository, so indexing writes
nothing into the working tree and a fresh clone needs `index_folder` once. The
repository id is derived from the checkout, so read it back from `resolve_repo` instead
of hard-coding it.

Fall back to `Read`, `Grep`, `Glob`, or `Bash` only when the path is not indexed or the
tools cannot answer the question. `Read` is still required before editing a file, so
read the one file you are about to change rather than exploring with it.

Call `jcodemunch_guide` for the version-current policy text; the summary above is not a
copy of it.

## Knowledge base memories

Store project memories under `memories/neobridge/neobridge/`. Write both segments in
lowercase, never `memories/neobridge/NeoBridge/`: vault paths are case-sensitive, so a
capitalized variant creates a second parallel directory rather than reusing the first.

| Content | Path |
| --- | --- |
| Decisions, architecture, conventions, session summaries | `memories/neobridge/neobridge/` |
| Code-review notes | `memories/neobridge/neobridge/reviews/` |
| User-wide preferences | `memories/global/` |
| Superseded memories | `memories/_archived/` |

- Call `rumi_rumi_kb_list` on the parent path before you create a project or repo
  directory, and reuse the casing you find there.
- Search before writing, using `rumi_rumi_kb_search` with `path: "memories/"`, so you
  extend an existing note instead of duplicating it.
- Reach the vault only through the `rumi_rumi_kb_*` tools. Do not read or write the
  vault folder with the shell or the file tools.

## Build and test

The Linux toolchain is installed in user space and is not on `PATH` by default.

```bash
export PATH="$HOME/.local/share/swiftly/bin:$PATH"
./Scripts/test-portable.sh
```

That script builds each package, runs its tests, checks the portability boundary, and
verifies that dependency resolution is pinned. Each package has its own `Package.swift`,
so run tests per package rather than from the repository root:

```bash
(cd Packages/NeoCore && swift test)
(cd Packages/NeoProtocol && swift test)
```

## Portability boundary

Sources under `Packages/*/Sources` must not import any of these:

    SwiftUI  AppKit  UIKit  WatchKit  TVUIKit  CoreBluetooth  CoreGraphics
    CoreData  CoreImage  CryptoKit  Combine  Metal  MapKit  XCTest

Foundation and Synchronization are allowed. `Scripts/test-portable.sh` checks this list
with grep, so a violation fails verification instead of surfacing in review.

## Evidence rules

- Do not claim that a protocol command or BLE feature works without official SDK
  evidence or a physical A1 trace. Leave unverified fields in `docs/protocol-a1.md`
  marked as pending.
- Keep destructive pen cleanup in `keepOnPen` mode until hardware acceptance tests pass
  on a real A1.
- Sanitize any captured pen traffic: no Bluetooth addresses, serial numbers, or
  authentication material. Raw captures belong in `Tests/Fixtures/raw/`, which is
  git-ignored.

## Repository state

Present today:

- `Packages/NeoCore`, `Packages/NeoProtocol` — portable packages.
- `Tests/Fixtures` — six sanitized fixtures plus `generate-fixtures.py`, which
  reimplements the wire format independently of the Swift codec so the tests
  cross-check the implementation instead of restating it. Regenerate only when a
  fixture must change, then review the generated diff.
- `Scripts/test-portable.sh` — the portable verification entry point.
- `docs/protocol-a1.md` — M0 protocol evidence and the hardware gate.
- `docs/portable-verification.md` — the recorded Linux verification run.

Planned but not present yet: `Packages/NeoStorage`, `Packages/NeoExport`,
`Apps/NeoBridgeMac`, `Scripts/remote-mac-build.sh`, `Tests/Integration`, and
`Tests/Hardware`. `openspec/config.yaml` describes what each should contain.

## Conventions

- Tests use XCTest rather than swift-testing, so the same suites can run under Xcode on
  the Mac runner.
- `Package.resolved` is committed on purpose, and
  `swift build --disable-automatic-resolution` verifies the pins hold. The first build
  on a cold machine still needs network access to fetch `swift-crypto` and `swift-asn1`.
- Packages use swift-tools-version 6.0, which defaults to the Swift 6 language mode, so
  strict concurrency applies. `NSLock` is unavailable from async contexts; use
  `Synchronization.Mutex` with `withLock` instead.
- XCTest assertions take autoclosures, so bind `await` and `try` expressions to a local
  variable before asserting on them.

## OpenSpec workflow

Changes live in `openspec/changes/<change-id>/`, each with a `tasks.md` and delta specs
under `specs/`. Archived changes move to `openspec/changes/archive/`. The `opsx-*`
commands and skills in `.opencode/` drive propose, apply, sync, update, and archive, and
are mirrored for other agent hosts under `.agents/`.

Keep the `tasks.md` checkboxes in step with the work as you go, and do not archive a
change while the portable tests fail. If a task is blocked on physical A1 hardware or
the macOS runner, leave it unchecked and record the blocker in the task note.
