# NeoBridge for macOS

A menu-bar app that reads offline strokes from a Neo Smartpen A1 over Bluetooth,
saves them to a durable local library, and writes deterministic page files to a
folder you choose. Strokes stay on the pen: cleanup is `keepOnPen`, and the app
sends no deletion command.

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
| Per-file failure line | At least one file could not be written | Names the file and the reason |
| **Retry Export** | A read saved but a file failed | Republishes the stored read's files |
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
| Complete | Strokes, dots, and distinct pages; the notes read; a notice of what was saved and written; and one line per file with its result (written, already up to date, or failed) |
| Failed | The error, a diagnostic when a transfer stopped after some packets, and a statement that no counts are shown because the read did not complete |

Partial counts are diagnostics only. A transfer that stops early is presented as
a failure, so a partial read is never labelled a completed sync. Retry is the
same **Read and Save Pen Data** command: every attempt builds a new transport and
a new session, so a retry starts a new scan rather than resuming the old one.

## What this version does not do

- No deletion. Cleanup stays `keepOnPen`: the session sends no `0x25` or `0x27`
  command, its evidence table blocks both, and `PenCleanupPolicy.deletionEnabled`
  is `false`. Strokes stay on the pen after a read.
- No connection codes or authentication beyond the SDK's default sixteen zero
  bytes. A pen that rejects that code fails with a clear message, and the app
  does not guess another.
- No live realtime streaming. Only offline data is read.
- No code signing or notarization.
