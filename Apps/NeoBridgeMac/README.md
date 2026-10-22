# NeoBridge for macOS

A menu-bar app that reads offline strokes from a Neo Smartpen A1 over Bluetooth,
saves them to a durable local library, and writes deterministic page files to a
folder you choose. It syncs on its own: discovery starts with the app, a read
starts when the pen appears, and another is offered at the interval you saved. You
choose once whether a sync removes its verified data from the pen or keeps the
pen's copy, and the app follows that saved setting until you change it.

For the recorded pen identity, a sync you saved as **Sync and Delete**, that
requests an export, and that has a writable library removes each packet from the
pen as it reads it — after the library has stored that packet, so what is removed
is what is already saved. The `0x25`/`0x27` deletion commands are unreachable: the
physical A1 trace of 2026-10-20 recorded that command's deletion scope as unsafe,
because the command removes a note's stored data as a whole, including strokes no
read had imported.

## What the app is made of

| Target | Contains | Runs where |
| --- | --- | --- |
| `NeoBridgeMacCore` | The Bluetooth adapter, the transport, the attempt runner, the shell's state machine, the saved sync settings, the automatic schedule, the durable library composition, and the export destination | Tested on macOS with `swift test` |
| `NeoBridgeMac` | The `@main` app: a `MenuBarExtra` and one window of SwiftUI views, plus the folder picker and the headless acceptance path | macOS only |
| `NeoBridgeMacCoreTests` | Unit tests for the adapter, the transport, the runner, the shell, the saved settings, the schedule, and the save/export flow | macOS only |

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

That bounded scan is the read's own pen-selection scan. The automatic schedule
runs a second, continuous scan that asks for duplicate advertisements, so a pen
that stays in range keeps reporting; the two never overlap. See
[Automatic sync](#automatic-sync).

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

## Automatic sync

The app syncs without being asked. Discovery starts at launch, a read starts when
a compatible pen appears, and another read is offered at each saved interval while
the app runs and is unpaused.

| Setting | Choices | First-install default |
| --- | --- | --- |
| Mode | **Sync and Delete**, **Sync and Retain**, **Pause** | Sync and Delete |
| Interval | 1, 5, 15, or 30 minutes | 5 minutes |

Both settings are saved as you select them, in `UserDefaults` beside the
export-folder bookmark but under their own keys, so neither feature disturbs the
other's stored value. A stored value this build does not understand is treated as
absent, so a value written by a later build never leaves the app without a usable
setting.

- **Sync and Delete** removes each packet the library has stored, as the deleting
  transfer that reads it acknowledges it. The saved mode is the authorization for
  each eligible automatic sync, so no extra click is needed per sync. Every transfer
  gate still decides: a sync with no export folder chosen, without safe transfer
  evidence, meeting a different pen, or without a writable library keeps the pen's
  copy, and Connection Details names the reason. An automatic sync never falls back
  to the separate deletion command, including after a refused route or an export
  retry.
- **Sync and Retain** reads the pen and keeps its copy. It requests no deletion.
- **Pause** stops discovery and the interval timer, so no pen is looked for and no
  read starts. A read already in flight finishes and reports itself. Selecting
  **Sync and Delete** or **Sync and Retain** saves that mode and resumes.

### Timing

- The interval is measured from the start of the previous attempt, so a read that
  outlasted the interval leaves the next opportunity already due. Several missed
  ticks coalesce into one attempt rather than stacking up.
- At most one read runs at a time. A tick that arrives while a read is in flight
  waits for it rather than starting a second read, and the schedule also waits while
  you are choosing between pens.
- A pen that stays in range is not synced again just because it is still
  advertising. Its advertisement counts as an appearance only when the app has not
  seen that pen before or the pen has been silent for 30 seconds, which is what
  makes a pen that left and came back sync at once instead of waiting for the
  interval. The 30-second baseline is refreshed when observation starts, so a read
  that outlasted it does not make the pen look like one that left and returned.
- An absent pen and a failed read are reported in Connection Details and paced by
  the interval. Neither starts a rapid retry loop.
- The observation scan asks CoreBluetooth for duplicate advertisements, which is
  the opposite of what the bounded pen-selection scan asks for. The radio runs one
  scan at a time, so the schedule stops observing before a read starts its selection
  scan and resumes afterwards.

### Where the app says what

The menu holds one compact status line, the saved settings, and the actions that
apply to the sync in progress. Counts, export paths, cleanup explanations, and
failure details are in **Connection Details**, so the menu stays a control surface
rather than a report. Both surfaces write the same saved settings, so a change in
either is what the next automatic attempt uses.

| Status line | When |
| --- | --- |
| **Idle** | No read has settled yet |
| **Syncing** | A read is running, or the app is waiting for you to choose between pens |
| **Paused** | Pause is the saved mode and no read is in flight |
| **Synced … ago** | The last read completed; the line shows the time since it |
| **Not Detected** | The last attempt found no pen advertising the expected name |
| **Failed** | The last attempt failed for a reason other than a missing pen |

A read in flight outranks the saved mode, so pausing during a read still reports
that read; the mode item's own checkmark is what says the schedule stopped. A read
that reached the pen and carried no strokes still counts as synced — the pen was
there and was read, so **Not Detected** would be false. A cancelled read records
nothing, so the previous status stays on show, and an export retry leaves it alone
whether it succeeds or fails: the line answers "when did the pen last sync", not
"when was a file last written". Connection Details names the specific reason behind
**Not Detected** or **Failed**.

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
| `NEOBRIDGE_ACCEPTANCE_CLEANUP` | The cleanup intent the run starts with: `keepOnPen` or `deleteAfterAcknowledge`, also as `keep` and `cleanup`. The intent is applied through the controller's per-read choice, which is the path a directly driven read uses; the menu is not involved, and the run starts no background schedule. | the policy default, cleanup |
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
  reported as unchanged. A changed JSON keeps up to three prior versions as
  `.bak1`, `.bak2`, and `.bak3`, but only when the record it replaces cannot be
  validated or holds strokes the library no longer has; a changed drawing or
  Markdown page is replaced without a backup.
- The output is deterministic: the bytes depend only on the stored strokes, in
  canonical order, never on arrival order, the transfer source, or the host. No
  Bluetooth address, serial number, or authentication material reaches a file,
  and the renderers carry no host metadata.
- There is no in-file merge. Each file is the page's current stored strokes.

### Folder and retry

- **Choose Export Folder…** in Connection Details asks for the destination once.
  The choice is stored as a security-scoped bookmark, so it survives a relaunch and
  keeps working if the app is sandboxed later. It is untouched by the sync settings,
  which live under their own `UserDefaults` keys.
- With no folder chosen, a sync is saved to the library and no files are written.
- **Retry Export** appears when a read saved but at least one file failed, in the
  menu while that read is the one shown and in Connection Details. It republishes
  from the stored rows without reading the pen again, so a retry can never invent a
  result from data that was not stored, and an automatic retry never sends a
  deletion command.

## Pen cleanup

The pen's copy of a read is the app's third outcome, reported separately from the
save and the export, because it says nothing about whether the library copy is
safe.

There are two cleanup routes, and the app can only use one of them:

- The **deleting transfer**, which the app uses. A sync saved as **Sync and Delete**,
  that requests an export, matches the recorded pen identity, and has durable packet
  storage asks the pen to remove each packet as part of the transfer that reads it.
  The library commits a packet before the app acknowledges it, so what is removed is
  what is already stored.
- The separate **`0x25`/`0x27` deletion commands**, which the app cannot send. The
  session supplies no deletion sender, so no such frame is built, and the command
  evidence record's deletion-scope verdict is `unsafe`. No automatic sync reaches
  this route at all, not even after a refused transfer or an export retry.

### What the saved mode means for the pen's copy

- **Sync and Delete** is the first-install default, and it is what the app follows
  until you change it. It authorizes the deleting transfer for each eligible
  automatic sync, so there is no per-sync confirmation click. Connection Details
  shows the statement the setting is about: "Sync and Delete removes each packet
  saved to the local library from the pen when the read acknowledges it. A read that
  requests no export, lacks safe transfer evidence, meets a different pen, or has no
  writable library keeps the pen's copy instead, and Connection Details names the
  reason."
- **Sync and Retain** reads the pen and keeps its copy. The read reports that the
  strokes were kept because retention was chosen.
- The setting is not proof that deletion happened. It asks for a deleting transfer;
  the transfer's own gates decide whether one runs, and the result the app reports is
  the transfer's, not the setting's.
- A mode or interval changed while a read is running applies to later attempts. The
  read already captured its own transfer, so changing the setting cannot change what
  that read does.
- The headless acceptance run is driven directly rather than by the schedule, so its
  deleting transfer stays behind its own explicit confirmation:
  `NEOBRIDGE_ACCEPTANCE_CONFIRM_CLEANUP` is what authorizes it, not a saved mode.

### When cleanup actually runs

A deleting transfer runs only when all four of its preconditions hold. Three of
them are decided before the app connects, and the fourth — the pen's identity — is
checked against the handshake:

- The sync requests an export. The pen's copy leaves as the read progresses, so the
  library plus the requested files is the user's path back to the data; a sync with
  no export folder chosen follows the ordinary retention rule instead.
- The saved mode is **Sync and Delete**, which is the authorization for an automatic
  sync.
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

**Cleanup is unavailable** appears in Connection Details while the deleting route
cannot run, naming the missing precondition: no export folder chosen, no writable
library, or transfer evidence that does not cover the connected pen. The sync still
runs; it saves, publishes, and reports the skip.

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
Dock icon, and closing the window leaves the menu-bar item in place. The menu shows
one status line, then the settings and the actions that apply to the sync in
progress; everything else the app reports is in **Connection Details**.

| Command | Shown when | What it does |
| --- | --- | --- |
| The status line, such as `Synced 3 minutes ago` | Always | Disabled text, not a command. It reads Idle, Syncing, Paused, the last completed read with its elapsed time, Not Detected, or Failed |
| **Sync and Delete** | Always, checked while it is the saved mode | Saves the mode and lets automatic syncs request a deleting transfer |
| **Sync and Retain** | Always, checked while it is the saved mode | Saves the mode; automatic syncs read the pen and keep its copy |
| **Pause** | Always, checked while it is the saved mode | Saves the mode; discovery and the interval timer stop, and a read in flight is left to finish |
| **Sync Interval** submenu | Always | Offers **1 minute**, **5 minutes**, **15 minutes**, and **30 minutes**, with the saved one checked |
| **Cancel Read** | A read is running | Stops the scan or the read and returns to idle |
| A numbered pen entry, such as `Neosmartpen_A1 (pen 1)` | Two or more pens matched | Reads the pen you pick |
| **Retry Export** | A read saved but a file failed | Republishes the stored read's files from the library |
| **Connection Details…** | Always | Opens the details window, brings it forward, and takes keyboard focus from the app you were using |
| **Quit NeoBridge** | Always | Quits the app |

Clicking the mode that is already checked clears its checkmark, which is not a
setting the app has, so the clear is ignored: the three modes are one choice, and
only selecting a different one changes it. The same applies to the interval.

The menu deliberately carries one status line and nothing else it would have to
explain: no counts, no export path, no cleanup prose, and no failure text. They are
in Connection Details, where there is room for them and where they stay out of the
way of the settings.

## Connection Details

The window shows what the menu leaves out.

| Section | Shows |
| --- | --- |
| Header | The current state, such as "Scanning for a pen", "Saving to the library", "Complete", or "Partial" |
| Result | Strokes, dots, and distinct pages; the notes read; a notice of what was saved and written; and one line per file with its result (written, already up to date, or failed) |
| Failure | The error, a diagnostic when a transfer stopped after some packets, and a statement that no counts are shown because the read did not complete |
| Pen choice | One button per matching pen, numbered rather than addressed |
| Sync settings | The same saved mode and interval the menu offers, what each means for the pen's copy, and the transfer gate that keeps a deleting transfer from running when one is closed |
| Export folder | The chosen folder, or that no folder is chosen, with **Choose Export Folder…** |
| Actions | **Cancel** while a read runs, **Retry Export** when a read saved but a file failed, and **Close** |

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
rather than a result. Every attempt builds a new transport and a new session, so an
attempt after a failure starts a new scan rather than resuming the old one, and the
schedule paces the next one at the saved interval.

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
