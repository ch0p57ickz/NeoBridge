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

The app is its own SwiftPM package and only builds on macOS:

```bash
(cd Apps/NeoBridgeMac && swift build)
(cd Apps/NeoBridgeMac && swift test)
```

## Mac build and packaging

`Scripts/remote-mac-build.sh` is the macOS entry point for the app. It runs
`Scripts/test-portable.sh`, builds the app with SwiftPM, gates on `xcodebuild`, and
assembles an ad-hoc-signed `NeoBridgeMac.app` in
`Apps/NeoBridgeMac/.build/bundle/`:

```bash
Scripts/remote-mac-build.sh                 # full verification, including the Xcode gate
Scripts/remote-mac-build.sh --configuration debug
SKIP_XCODE_GATE=1 Scripts/remote-mac-build.sh   # skips the gate and says so; not full verification
```

The bundle is assembled by the script, not by SwiftPM, because CoreBluetooth reads its
usage description from `Info.plist`, which a bare `swift run` executable does not have.
To run the built app:

```bash
open Apps/NeoBridgeMac/.build/bundle/NeoBridgeMac.app
```

`Scripts/package-app.sh` turns that bundle into something that can travel. It builds
through `remote-mac-build.sh` (or reuses the last bundle with `--skip-build`), signs
with a Developer ID when `DEVELOPER_ID_APPLICATION` is set, notarizes when
`NOTARY_PROFILE` and that identity are both set — a profile without an identity exits
2 instead of shipping an unnotarized archive — and writes
`Apps/NeoBridgeMac/.build/packages/NeoBridgeMac-<version>.zip`. With neither variable
set it packages the ad-hoc bundle, which is refused by Gatekeeper on another Mac until
its quarantine attribute is cleared. It repeats the build's own `PASSED`/`INCOMPLETE`
verdict for a full run instead of computing one, and reports `INCOMPLETE` itself for
`--skip-build`.

```bash
Scripts/package-app.sh
Scripts/package-app.sh --skip-build --output ~/Desktop
```

`SKIP_XCODE_GATE=1` exists for a host whose Xcode installation cannot run
`xcodebuild`. A run that uses it prints `INCOMPLETE` and must not be recorded as
satisfying the Xcode gate.

To run one headless read against a physical pen and keep a transcript — this is how
the acceptance checklist in `Tests/Hardware/README.md` is filled in, since a menu-bar
app cannot be scripted without an accessibility grant:

```bash
NEOBRIDGE_ACCEPTANCE_TRACE=/tmp/a1-run.txt \
  Apps/NeoBridgeMac/.build/bundle/NeoBridgeMac.app/Contents/MacOS/NeoBridgeMac
```

Run it from inside the bundle, because CoreBluetooth reads its usage description from
`Info.plist`. The exit status is 0 for a completed read and 1 for a failed one, and
the transcript's last `outboundCommands` line is the deletion check. A pen that is
powered down advertises nothing at all, which an independent scan confirms.

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
- Keep destructive pen cleanup behind per-route evidence: a route may remove the pen's
  copy only while its own record's verdicts are safe, and every verdict has to come from
  a physical A1 trace. The records and the verdicts they currently carry are in
  `docs/protocol-a1.md`. Cleanup is the default intent, but the intent alone never sends
  a deletion: the gate is data, not a boolean.
- Sanitize any captured pen traffic: no Bluetooth addresses, serial numbers, or
  authentication material. Raw captures belong in `Tests/Fixtures/raw/`, which is
  git-ignored.

## Repository state

Present today:

- `Packages/NeoCore`, `Packages/NeoProtocol` — portable packages.
- `Apps/NeoBridgeMac` — the macOS menu-bar app package: `NeoBridgeMacCore` (Bluetooth
  adapter, transport, attempt runner, shell state machine) plus the `NeoBridgeMac`
  executable. Its `README.md` records the BLE assumptions and the menu commands.
- `Tests/Fixtures` — sanitized fixtures plus `generate-fixtures.py`, which
  reimplements the wire format independently of the Swift codec so the tests
  cross-check the implementation instead of restating it. Regenerate only when a
  fixture must change, then review the generated diff.
- `Tests/Hardware/README.md` — the physical A1 connect-and-sync acceptance checklist.
- `Tests/Hardware/PenLab` — a macOS-only package for the pen's destructive paths: the
  two deletion commands, framed by its own codec because the app cannot build them,
  and a `next-delete` experiment that drives a `0x23` transfer with the deleting
  option. PenLab is not in any app target and not in the portable package list;
  `README.md` in `Tests/Hardware` records how to build and run it.
- `Scripts/test-portable.sh` — the portable verification entry point.
- `Scripts/remote-mac-build.sh` — the Mac build, Xcode gate, and bundle assembly.
- `Scripts/pen-lab-build.sh` — the PenLab build and bundle assembly.
- `docs/protocol-a1.md` — M0 protocol evidence and the hardware gate.
- `docs/portable-verification.md` — the recorded verification runs.

`Packages/NeoStorage` and `Packages/NeoExport` hold the durable library and the
deterministic export, and `Tests/Integration` holds the fake-transport integration
scenarios. `openspec/config.yaml` describes what each contains.

## Conventions

- Tests use XCTest rather than swift-testing, so the same suites can run under Xcode on
  the Mac runner.
- `Package.resolved` is committed on purpose, and
  `swift build --disable-automatic-resolution` verifies the pins hold. The first build
  on a cold machine still needs network access to fetch `swift-crypto` and `swift-asn1`.
- Packages use swift-tools-version 6.0, which defaults to the Swift 6 language mode, so
  strict concurrency applies. `NSLock` is unavailable from async contexts; use
  `Synchronization.Mutex` with `withLock` instead. `Mutex` is macOS 15.0 and later, so
  `Packages/NeoProtocol` declares `.macOS(.v15)` and any macOS target that links
  `Packages/NeoProtocol` must declare the same floor. Linux has no availability gate, so
  a missed floor passes on Linux and fails only under the Apple toolchain.
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
