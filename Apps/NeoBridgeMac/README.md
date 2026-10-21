# NeoBridge for macOS

A menu-bar app that reads offline strokes from a Neo Smartpen A1 over Bluetooth,
saves them to a durable local library, and writes deterministic page files to a
folder you choose. Each read intends to remove its verified data from the pen, and
you can keep the strokes on the pen for one read instead. For the recorded pen
identity, a read you have confirmed, that requests an export, and that has a
writable library removes each packet from the pen as it reads it — after the library
has stored that packet, so what is removed is what is already saved. The
`0x25`/`0x27` deletion commands are unreachable: the physical A1 trace of 2026-10-20
recorded that command's deletion scope as unsafe, because the command removes a
note's stored data as a whole, including strokes no read had imported.

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
result, whichever way the transport classified the disconnect. A deleting read
that stops that way is presented as **Partial** rather than as a completion: the
packets it durably committed stay in the library, and the pen may still hold the
remainder.

An attempt also releases the pen when it ends, whether it succeeded or failed.
Disconnecting removes nothing itself: an ordinary read sent only a non-destructive
transfer option, and a deleting read removed exactly the packets it had already
committed and acknowledged. Holding the link would be worse than
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

Three more variables vary the attempt, so one binary can run the whole physical-A1
checklist, including the experiment that decides which `0x23` transfer option is
incremental:

| Variable | Effect | Default |
| --- | --- | --- |
| `NEOBRIDGE_ACCEPTANCE_TRANSFER_OPTION` | The `0x23` transfer option the read sends: `notNextTransfer`, `nextAndReserve`, or the option byte in decimal or hexadecimal. | `nextAndReserve`, the established non-destructive option |
| `NEOBRIDGE_ACCEPTANCE_CLEANUP` | The cleanup intent the run starts with: `keepOnPen` or `deleteAfterAcknowledge`, also as `keep` and `cleanup`. The intent is set through the same method the menu calls. | the policy default, cleanup |
| `NEOBRIDGE_ACCEPTANCE_CONFIRM_CLEANUP` | Whether the run confirms cleanup for its sync, as `true`/`yes`/`1` or `false`/`no`/`0`. The confirmation is what authorizes a deleting transfer, so it is a separate key: asking for the intent alone takes the ordinary non-destructive read. | unset, not confirmed |
| `NEOBRIDGE_ACCEPTANCE_ABORT_AT_PACKET` | Drops the pen link when that `0x24` packet arrives, so the transfer fails part way on purpose. The packet is not delivered, so the read assembles one fewer packet than the number. | unset, the transfer runs to its end |

A value that cannot be understood is refused: the process prints the accepted
values and exits 2 rather than running a different experiment than the one asked
for. `NEOBRIDGE_ACCEPTANCE_TRANSFER_OPTION=nextAndDelete` (`0x01`) is refused,
because that key cannot select the deleting option; a deleting run asks for it with
`NEOBRIDGE_ACCEPTANCE_CLEANUP=cleanup` together with
`NEOBRIDGE_ACCEPTANCE_CONFIRM_CLEANUP=true`. A confirmation combined with
`NEOBRIDGE_ACCEPTANCE_CLEANUP=keep` is refused too, because it would confirm
nothing.

```bash
NEOBRIDGE_ACCEPTANCE_TRACE=/tmp/a1-run.txt \
NEOBRIDGE_EXPORT_DIRECTORY=/tmp/a1-exports \
  .build/bundle/NeoBridgeMac.app/Contents/MacOS/NeoBridgeMac

NEOBRIDGE_ACCEPTANCE_TRACE=/tmp/a1-option-00.txt \
NEOBRIDGE_ACCEPTANCE_TRANSFER_OPTION=notNextTransfer \
  .build/bundle/NeoBridgeMac.app/Contents/MacOS/NeoBridgeMac

NEOBRIDGE_ACCEPTANCE_TRACE=/tmp/a1-aborted.txt \
NEOBRIDGE_ACCEPTANCE_ABORT_AT_PACKET=100 \
  .build/bundle/NeoBridgeMac.app/Contents/MacOS/NeoBridgeMac
```

The transcript opens with a `run` line naming the option, the cleanup intent, and
the abort, so a recorded run states the experiment it belonged to.

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

There are two cleanup routes, and the app can only use one of them:

- The **deleting transfer**, which the app uses. A read that requests an export,
  has the user's confirmation for that sync, matches the recorded pen identity, and
  has durable packet storage asks the pen to remove each packet as part of the
  transfer that reads it. The library commits a packet before the app acknowledges
  it, so what is removed is what is already stored.
- The separate **`0x25`/`0x27` deletion commands**, which the app cannot send. The
  session supplies no deletion sender, so no such frame is built, and the command
  evidence record's deletion-scope verdict is `unsafe`.

### What the app intends by default

- Every read intends cleanup. The menu and the window show the statement the
  confirmation is about: "If you confirm cleanup for this read, each packet saved to
  the local library is removed from the pen when the read acknowledges it. The files
  requested for this read are exported afterwards; if that export fails, retry it
  from the local library."
- Cleanup still needs a confirmation for each sync. The line under the statement
  names which transfer the choice applies to, so the buttons always say what they
  apply to.
- **Keep Strokes on the Pen for This Read** retains the pen's copy for the transfer
  the line names: the retry of a read whose files failed, or the next read. The
  transfer that consumes the choice uses it once, so the default intent is presented
  again afterwards.
- **Remove Them After a Successful Read** restores the default cleanup intent for
  the same transfer.
- **Remove Acknowledged Packets for This Read** confirms cleanup for one read. It is
  what authorizes the deleting transfer, it is offered only while cleanup is
  intended, available, and still unconfirmed, and it is cleared when that read
  starts, so a later sync cannot inherit it. It is not offered while a completed
  read's files can still be published again, because a retry publishes from the
  library and removes nothing.
- Neither the retain nor the remove button appears while a read is running: a
  running read captured its intent when it started, so a later choice could not
  reach it. Asking which pen to use is not a read, so a choice made before that
  question still holds for the pen you pick. Neither appears after a deleting read
  whose files still need publishing either: that read removed the packets it stored
  as it read them, so its **Retry Export** only republishes the durable copy and a
  choice there could keep nothing.

### When cleanup actually runs

A deleting transfer runs only when all four of its preconditions hold. Three of
them are decided before the app connects, and the fourth — the pen's identity — is
checked against the handshake:

- The sync requests an export. The pen's copy leaves as the read progresses, so the
  library plus the requested files is the user's path back to the data; a read with
  no export folder chosen follows the ordinary retention rule instead.
- The user confirmed cleanup for this sync.
- The connected pen matches the recorded identity: NWP-F151, firmware 3.00,
  protocol 2.23, uncompressed. A different identity takes the ordinary
  non-destructive read and the app names the blocker, because the pen's identity is
  only known after the handshake.
- A writable library is available to commit packets to.

Each packet is committed and flushed before its acknowledgement, so a packet that
is removed from the pen is already stored. The export happens afterwards, so a
failed export is retried from the library and never re-reads the pen.

A deleting read that ends before its first packet — a dropped link, a refused or
malformed response, a failed first commit, or a cancel — saved nothing and asked the
pen for nothing, so it leaves the batch it had opened marked failed. The row stays in
the library as the record that a read was attempted; it can never publish, because
publication needs a durable packet. A read that stops after some packets is the
partial case above, not this one.

The route is enabled. Its evidence comes from the 2026-10-21 runs, which were
driven by PenLab rather than by this app, and its ordering and refusal behavior are
covered by the portable tests against fake transports; the app's own end-to-end
deleting read against a pen is the acceptance run `Tests/Hardware/README.md` still
lists as outstanding.

The separate `0x25`/`0x27` commands have their own stricter rule — a completed,
fully published read of the read's own verified scope, with the command evidence
gate open — and it is not satisfied in this build, so the pen's copy is never
reclaimed that way.

### While a precondition is missing

**Cleanup is unavailable** appears while the deleting route cannot run, naming the
missing precondition: no export folder chosen, no writable library, or transfer
evidence that does not cover the connected pen. The read still runs; it saves,
publishes, and reports the skip.

The command gate is data, not a switch. `PenDeletionEvidence` holds a verdict for
each safety condition — payload framing, exact deletion scope, response meaning, and
interrupted-transfer retention — and `PenCleanupPolicy.deletionEnabled` derives from
those verdicts, so opening it is a change to the recorded evidence rather than an
edit to a boolean. The record this build carries is the physical A1 trace of
2026-10-20, which settles three conditions and refuses the fourth, so the line names
the deletion scope. The transfer route has its own record,
`PenDeletingTransferEvidence`, built from the 2026-10-21 runs.

### What the app reports

| Outcome | What the app says |
| --- | --- |
| Retained by choice | "The pen's strokes were kept on the pen because retention was chosen for this read." |
| Acknowledged packet prefix | "Removed the acknowledged packet prefix from the pen: N acknowledged packets. The library copy remains available.", or, when the read has no recorded completion, "Removed only the acknowledged packet prefix from the pen: …" followed by either "The read stopped before the end, so the pen may still hold the remainder." or, when the transfer reached its last packet, "The transfer reached the last packet, so the pen holds no remainder of it; the read's completion could not be recorded, so it is reported as incomplete." A last acknowledgement that was not confirmed adds that the pen's copy of that packet is uncertain. |
| Reclaimed | "Reclaimed N pages from the pen. The library copy remains available." |
| Skipped, with the blocking condition | "The pen kept its strokes: …", naming the missing precondition, the command gate condition, the export that never published in full, or the missing pen link |
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
| Cleanup outcome line | A read completed | Says what happened to the pen's copy. A deleting read shows the acknowledged packet prefix, that retention was chosen, or a skip with its blocking condition; the separate command route's reclaimed and outstanding outcomes are the ones this build cannot produce, because no deletion command is sent |
| Per-file failure line | At least one file could not be written | Names the file and the reason |
| **Retry Export** | A read saved but a file failed | Republishes the stored read's files |
| Cleanup statement line | Always | The statement the confirmation is about: "If you confirm cleanup for this read, each packet saved to the local library is removed from the pen when the read acknowledges it. The files requested for this read are exported afterwards; if that export fails, retry it from the local library." |
| Cleanup intent line | Always | Names the intent on screen and what the choice applies to: "Removing each acknowledged packet from the pen as this read progresses.", "Keeping the pen's strokes for this read; cleanup was not confirmed.", "Retry Export publishes files from the library and removes nothing from the pen.", "The next read can remove acknowledged packets once you confirm cleanup for it.", or the same line with "keeps the pen's strokes" when retention was chosen or cleanup is unavailable |
| **Keep Strokes on the Pen for This Read** | No attempt is running, cleanup is the intent on screen, and no deleting read's retry is pending | Retains the pen's copy for the transfer the intent line names |
| **Remove Them After a Successful Read** | No attempt is running, retention is the intent on screen, and no deleting read's retry is pending | Restores the default cleanup intent for the transfer the intent line names |
| **Remove Acknowledged Packets for This Read** | No attempt is running, cleanup is intended and available, this sync is not yet confirmed, and no deleting read's retry is pending | Confirms cleanup for one read, which is what authorizes the deleting transfer |
| Cleanup-unavailable line | The deleting route cannot run | "Cleanup is unavailable: …", naming the missing precondition: no export folder chosen, no writable library, or transfer evidence that does not cover the connected pen |
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
| Partial | The same counts and lines as Complete, for a deleting read with no recorded completion: the notice says whether the read stopped before the end and the pen may still hold the remainder, or that the transfer reached its last packet and the completion could not be recorded |
| Failed | The error, a diagnostic when a transfer stopped after some packets, and a statement that no counts are shown because the read did not complete |

A partial read is never labelled a completed sync. An ordinary transfer that stops
early is presented as a failure; a deleting read that stops early is presented as
**Partial**, because what it holds is the durable prefix it acknowledged while the
pen may still hold the rest. In both cases the partial counts are diagnostics
rather than a result. Retry is the same **Read and Save Pen Data** command: every
attempt builds a new transport and a new session, so a retry starts a new scan
rather than resuming the old one.

## What this version does not do

- No `0x25` or `0x27` deletion command. The session supplies no deletion sender,
  so no such frame is built, the evidence table gates both behind the command
  deletion evidence, and `PenCleanupPolicy.deletionEnabled` derives from that
  evidence, whose recorded deletion-scope verdict is `unsafe`. The deleting transfer
  is the only route the app has, and it removes only the packets the library has
  already stored.
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
