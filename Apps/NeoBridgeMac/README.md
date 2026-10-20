# NeoBridge for macOS

A menu-bar app that reads offline strokes from a Neo Smartpen A1 over Bluetooth,
saves them to a durable local library, and writes deterministic page files to a
folder you choose. Each read intends to remove its verified data from the pen once
it is saved and its files are written, and you can keep the strokes on the pen for
one read instead. Deletion is unreachable in this build: the pen's copy is retained
until a physical A1 trace opens the deletion evidence gate.

## What the app is made of

| Target | Contains | Runs where |
| --- | --- | --- |
| `NeoBridgeMacCore` | The Bluetooth adapter, the transport, the attempt runner, the shell's state machine, the durable library composition, and the export destination | Tested on macOS with `swift test` |
| `NeoBridgeMac` | The `@main` app: a `MenuBarExtra` and one window of SwiftUI views, plus the folder picker and the headless acceptance path | macOS only |
| `NeoBridgeMacCoreTests` | Unit tests for the adapter, the transport, the runner, the shell, and the save/export flow | macOS only |

Protocol logic lives in `Packages/NeoProtocol`, storage in `Packages/NeoStorage`,
and export in `Packages/NeoExport`. All three are portable. The app package is a
thin adapter over them, so the handshake, version gate, discovery, assembly,
commit, and file publication are all exercised on Linux with `FakePenTransport`.

The app links the portable packages, so it inherits their macOS 15.0 deployment
floor. `Packages/NeoProtocol` uses `Synchronization.Mutex`, which is macOS 15.0
and later.

## Bluetooth assumptions

### Discovery

The pen is matched on its **advertised name**, `Neosmartpen_A1`. It advertises a
random static address that changes on every power cycle, so an address is never
a match key, is never stored, and is never shown. On macOS a CoreBluetooth
identifier is derived from that address, so the app numbers candidates instead
of printing an identifier.

A scan always runs for a window before it decides, because a scan that
connected on its first match could not tell one pen from two. The window is thirty
seconds at most, and it ends one second after the first match so that a single pen
does not cost the full window on every read. The maximum is sized for a pen that has
just been switched on, not for an awake pen. While it is awake the A1 advertises in
bursts: its first advertisement after a scan started arrived as late as 2.5 seconds
in. The delay after a switch-on varied in two measurements — once the pen was still
invisible six seconds later, and once it advertised about three seconds in — and a
window that is too short reports "no pen found" with the pen sitting in range. The
full window is paid only when no pen is advertising at all, and **Cancel Read**
ends even that. If two or more pens advertise the name during the window, the app
asks you to choose one and then reconnects with that explicit choice. It never picks
silently.

The scan narrows on the two documented service identifiers, so the radio does
the first filter in hardware:

| Role | 16-bit form | 128-bit form |
| --- | --- | --- |
| Service | `19F1` | `4F99F138-9D53-5BFA-9E50-B147491AFE68` |
| Write characteristic | `2BA0` | `8bc8cc7d-88ca-56b0-af9a-9bf514d0d61a` |
| Notify characteristic | `2BA1` | `64cd86b1-2256-5aeb-9f04-2caf6c60ae57` |

These values and the write mode come from the Neo iOS SDK 3.0,
`NISDK3/Classes/Common/Global.swift` at commit `a53a01e`. The SDK scans with
both service forms and writes with `CBCharacteristicWriteType.withResponse`, so
every write is awaited before the next one starts.

### Channels

Outbound frames go to the write characteristic, sliced into 20-byte writes,
which is the one-call maximum the SDK uses. The pen reassembles a frame from its
marker bytes.

Inbound notifications are forwarded as raw chunks in arrival order. The app does
not buffer frames: the portable decoder is stateful across chunks, so a frame
split across two notifications still decodes, and that behavior has a test.

### Disconnect and interruption

The inbound stream finishes when the pen disconnects normally and throws when
the connection is interrupted. A stream that finishes before the session has
received an end-position packet is an incomplete transfer, never a completed
result, whichever way the transport classified the disconnect.

An attempt also releases the pen when it ends, whether it succeeded or failed.
Disconnecting sends no deletion request: the request used the next-and-reserve
option, so the strokes stay on the pen. Holding the link would be worse than
untidy — a connected pen stops advertising, so the app's own next read would
report that no pen was found, and the pen would stay unavailable to its other
owners.

### Permission

The app declares `NSBluetoothAlwaysUsageDescription`, and the build script puts
it in `Info.plist`. The app checks the adapter state before it scans, so a
denied request reports that permission is required and **never turns on the
radio**. CoreBluetooth reports `.unknown` for a moment after the manager is
created, so the state is waited for within a two-second grace window rather than
reported as unavailable; a read started immediately after launch therefore scans
instead of failing. A powered-off adapter reports its own state, including when
Bluetooth is switched off while a scan is running: the adapter fails the scan and
the pending setup waits at once, so the shell shows the adapter state rather than
reporting a missing pen. If the notify characteristic exists but the subscription
is refused, the connection fails before the version request is sent.

## Building and running

See `docs/portable-verification.md` for the recorded commands, and
`Scripts/remote-mac-build.sh` for the entry point that builds the portable
packages, runs their tests, builds the app, and assembles a launchable bundle.

For the unit tests alone:

```bash
cd Apps/NeoBridgeMac
swift test
```

The tests drive the transport and the shell through fakes, so they need no
radio, no pen, and no permission grant.

### Packaging for another Mac

`Scripts/package-app.sh` builds through `Scripts/remote-mac-build.sh`, then writes
a zip of the whole bundle so it can travel to another machine:

```bash
Scripts/package-app.sh                                 # verify, build, then package
Scripts/package-app.sh --skip-build --output ~/Desktop # package the last build
```

The archive is named `NeoBridgeMac-<version>.zip`, holds `NeoBridgeMac.app`, and
lands in `Apps/NeoBridgeMac/.build/packages` unless `--output` says otherwise.
Unpack it on the target with `ditto -x -k <archive> /Applications` and open it.

The script reports the build's own verdict, so a run that skipped a gate says
`INCOMPLETE` rather than `PASSED`. It signs with a Developer ID and notarizes when
`DEVELOPER_ID_APPLICATION` and `NOTARY_PROFILE` are set, and it fails at once when
`NOTARY_PROFILE` is set without an identity. With neither set it packages the
ad-hoc bundle that the build script signs, which is enough for your own machines
and not for anyone else's: clear the quarantine attribute on the target, or open
the app with a right click.

### Headless acceptance run

`Tests/Hardware/README.md` needs the app to read a real pen, save it, write its
files, and keep a transcript of the framed bytes it sent, and a menu-bar app
cannot be driven into that from a script without an accessibility grant. The same
binary therefore runs one headless read attempt when `NEOBRIDGE_ACCEPTANCE_TRACE`
names a file: it builds the controller the user interface uses, starts one read,
waits for it to finish, writes the transcript, and exits non-zero when the read
did not complete. Only the presentation is skipped — the same adapter, transport,
runner, portable session, library, and publisher do the work.

A headless run cannot open a folder picker, so the export folder comes from
`NEOBRIDGE_EXPORT_DIRECTORY`. The interface stores a security-scoped bookmark
instead.

```bash
NEOBRIDGE_ACCEPTANCE_TRACE=/tmp/a1-run.txt \
NEOBRIDGE_EXPORT_DIRECTORY=/tmp/a1-exports \
  .build/bundle/NeoBridgeMac.app/Contents/MacOS/NeoBridgeMac
```

Run it from inside the bundle, because CoreBluetooth reads its usage description
from `Info.plist`. On an ordinary launch, with the variable unset, the app is the
menu-bar app.

## Saving and exporting

A read has two separate outcomes, and the app reports them separately: a read
that committed is **saved** even when a file could not be written, and export
success is claimed only when every requested file is in place.

### Durable library

- Every completed read is committed in one transaction to a SQLite database in
  WAL mode at `~/Library/Application Support/NeoBridge/library.sqlite`. The
  directory is created on first use, outside the app bundle, so an app update
  never touches your strokes.
- The schema is versioned. A database written by a newer build is refused with a
  clear message rather than opened and damaged.
- Strokes are deduplicated by the canonical fingerprint of the page, origin
  time, and ordered points. A stroke whose origin time is not reliable is always
  kept, so two different marks cannot collapse into one. Re-reading the same
  note therefore adds nothing new; the read reports how many strokes were added
  and how many were already stored.

### Page files

- Every page that carries a stroke produces one file per format: JSON, SVG, and
  Markdown. A page with no stroke produces no file.
- The four-part file name carries every page component, for example
  `ncode-s3-o27-b700-p1.json`, so two pages that differ only in section, owner,
  or book cannot collide.
- Files are written to a sibling temporary file, flushed, and renamed into
  place, so an interrupted write never leaves a half-written page.
- If the generated bytes already match the target, the file is left as it is and
  reported as unchanged. Otherwise the previous three versions are kept as
  `.bak1`, `.bak2`, and `.bak3`.
- The output is deterministic: the bytes depend only on the stored strokes, in
  canonical order, never on arrival order, the transfer source, or the host. No
  Bluetooth address, serial number, or authentication material reaches a file,
  and the renderers carry no host metadata.
- There is no in-file merge. Each file is the page's current stored strokes.

### Folder and retry

- **Choose Export Folder…** asks for the destination once. The choice is stored
  as a security-scoped bookmark, so it survives a relaunch and keeps working if
  the app is sandboxed later.
- With no folder chosen, a read is saved to the library and no files are
  written.
- **Retry Export** appears when a read saved but at least one file failed. It
  republishes from the stored rows without reading the pen again, so a retry can
  never invent a result from data that was not stored.

## Pen cleanup

The pen's copy of a read is the app's third outcome, reported separately from the
save and the export, because it says nothing about whether the library copy is
safe.

### What the app intends by default

- Every read intends cleanup. Before a transfer the menu and the window say
  "Strokes are normally removed from the pen after they are saved and their files
  are written."
- The controller keeps two intents: the one the next read will use, and the one the
  read in flight — or the completed read a **Retry Export** can still finish —
  already captured. The line under the statement names which of the two is on
  screen, so the buttons always say what the choice applies to.
- **Keep Strokes on the Pen for This Read** retains the pen's copy for the transfer
  the line names: the retry of a read whose files failed, or the next read. The
  transfer that consumes the choice uses it once, so the default intent is presented
  again afterwards.
- **Remove Them After a Successful Read** restores the default intent for the same
  transfer.
- Neither button appears while a read is running: a running read captured its intent
  when it started, so a later choice could not reach it. Asking which pen to use is
  not a read, so a choice made before that question still holds for the pen you pick.

### When cleanup actually runs

Cleanup is requested only after the read is stored and published, and only for the
read's own verified scope:

- The transfer must have completed and committed durably to the library.
- An export must have published in full. A read whose files failed or only partly
  published keeps its pen data, and so does a read saved with no export folder
  chosen: with nothing published, the library copy is the read's only copy, so the
  pen's copy is retained and the app names the batch's state.
- The read must have stored at least one page. The app never asks for cleanup of an
  empty read — it reports that no stroke was found instead — and the library
  refuses an empty scope as well.
- The read must be the only one touching its pages: a page that a sync which has
  not completed also touches is retained, so a later failed note keeps its strokes
  on the pen even after an earlier note completes.
- The deletion evidence gate must be open. It is closed in this build, so the pen's
  copy is retained and the app says why.

### While the gate is closed

**Cleanup is unavailable** appears while the deletion evidence gate is closed,
naming the blocking condition, and the read still runs: it saves, publishes, and
reports the skip. The
gate is data, not a switch. `PenDeletionEvidence` holds a verdict for each safety
condition — payload framing, exact deletion scope, response meaning, and
interrupted-transfer retention — and `PenCleanupPolicy.deletionEnabled` derives
from those verdicts, so opening the gate is a change to the recorded evidence
rather than an edit to a boolean. The app never supplies a deletion sender, so no
deletion frame is built at all.

### What the app reports

| Outcome | What the app says |
| --- | --- |
| Retained by choice | "The pen's strokes were kept on the pen because retention was chosen for this read." |
| Reclaimed | "Reclaimed N pages from the pen. The library copy remains available." |
| Skipped, with the blocking condition | "The pen kept its strokes: …", naming the gate condition, the export that never published in full, or the missing pen link |
| Outstanding | "A deletion request is outstanding: … The library copy is unaffected and the request is not repeated automatically." |

A request whose effect is unknown stays outstanding in the library's journal, and it
is never resent automatically. Resolving it needs a fresh read that returned the
pen's whole stored-page inventory, which is compared with the recorded scope; the
portable importer exposes that as `resolveCleanup(_:storedPages:)`, and the app does
not drive it yet. A read that returns only new data is not an inventory, so it
resolves nothing.

## Menu commands

The app runs as an accessory: `Info.plist` sets `LSUIElement`, so there is no
Dock icon, and closing the window leaves the menu-bar item in place.

| Command | Shown when | What it does |
| --- | --- | --- |
| Summary line | Always | Shows the current state, such as "Scanning for a pen", "Saving to the library", or "Complete" |
| **Read and Save Pen Data** | No attempt running and no choice pending | Scans, connects, reads the pen's offline data, saves it, and writes its page files |
| **Cancel Read** | An attempt is running | Stops the scan or the read and returns to idle |
| A numbered pen entry, such as `Neosmartpen_A1 (pen 1)` | Two or more pens matched | Reads the pen you pick |
| Result line | A read completed | Shows strokes, dots, and distinct pages, plus a notice of what was saved and written |
| Cleanup outcome line | A read completed | Says what happened to the pen's copy: retained by choice, reclaimed, skipped with its blocking condition, or outstanding |
| Per-file failure line | At least one file could not be written | Names the file and the reason |
| **Retry Export** | A read saved but a file failed | Republishes the stored read's files |
| Cleanup statement line | Always | "Strokes are normally removed from the pen after they are saved and their files are written." |
| Cleanup intent line | Always | Names the intent on screen and what the choice applies to: "Removing the pen's strokes when this read completes.", "Retry Export keeps the pen's strokes.", or "The next read removes the pen's strokes after they are saved." |
| **Keep Strokes on the Pen for This Read** | No attempt is running and cleanup is the intent on screen | Retains the pen's copy for the transfer the intent line names |
| **Remove Them After a Successful Read** | No attempt is running and retention is the intent on screen | Restores the default cleanup intent for the transfer the intent line names |
| Cleanup-unavailable line | The deletion evidence gate is closed | "Cleanup is unavailable: …", naming the condition that is not established |
| **Choose Export Folder…** | Always | Picks the folder page files are written into and remembers it |
| Export-folder line | Always | Shows the chosen folder, or that no folder is chosen |
| Failure line | A read failed | Shows the human-readable error |
| **Connection Details…** | Always | Opens the details window, brings it forward, and takes keyboard focus from the app you were using |
| **Quit NeoBridge** | Always | Quits the app |

The action that retrieves strokes is labelled **Read and Save Pen Data**, because
that is what it does: it commits the strokes and writes the files.

## Shell states

The window shows one state at a time.

| State | Window shows |
| --- | --- |
| Idle | "No pen data has been read yet." |
| Scanning, Connecting, Verifying, or Syncing | A spinner, the current stage, and a note that counts from an earlier read are hidden while a read runs |
| Saving to the library | A spinner and the commit step |
| Writing export files | A spinner and the publication step |
| Choose a pen | One button per matching pen, numbered rather than addressed |
| Complete | Strokes, dots, and distinct pages; the notes read; a notice of what was saved and written; what happened to the pen's copy; and one line per file with its result (written, already up to date, or failed) |
| Failed | The error, a diagnostic when a transfer stopped after some packets, and a statement that no counts are shown because the read did not complete |

Partial counts are diagnostics only. A transfer that stops early is presented as
a failure, so a partial read is never labelled a completed sync. Retry is the
same **Read and Save Pen Data** command: every attempt builds a new transport and
a new session, so a retry starts a new scan rather than resuming the old one.

## What this version does not do

- No deletion. Cleanup is the intent, but the pen's copy is retained: the session
  sends no `0x25` or `0x27` command, the evidence table gates both behind the
  deletion evidence, and `PenCleanupPolicy.deletionEnabled` derives from that
  evidence, which has no safe verdict yet. The app supplies no deletion sender, so
  no deletion frame is built. Strokes stay on the pen after a read, and the app
  says why.
- No connection codes or authentication beyond the SDK's default sixteen zero
  bytes. A pen that rejects that code fails with a clear message, and the app
  does not guess another.
- No live realtime streaming. Only offline data is read.
- No Developer ID signing and no notarization. The bundle the build assembles is
  ad-hoc signed, so another Mac refuses it until its quarantine attribute is
  cleared or it is opened with a right click. `Scripts/package-app.sh` signs with
  a Developer ID and notarizes when `DEVELOPER_ID_APPLICATION` and
  `NOTARY_PROFILE` are both configured. The target machine also has to run
  macOS 15 or later. The recorded build is arm64: neither script pins an
  architecture, so no universal binary is produced.
