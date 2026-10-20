# Physical A1 acceptance

This is the checklist for running connect-and-sync against a real Neo Smartpen
A1. It covers every scenario in the three specifications this change adds, so a
run either ticks a row or records why it could not.

Status of the last run: **run on 2026-10-19 against a physical A1.** The headless
acceptance mode read the pen fourteen times, including four consecutive reads, three
more after the fixes below landed, and two more with the pen switched off and on again
mid-read, and the rows it exercises are ticked below. Rows
that need a second pen, a Bluetooth toggle, a denied permission prompt, or the window
behaviour of the SwiftUI shell were not reached during that run and are marked as
unverified with the reason; the details-window command was reached on first use
afterwards and is recorded in its row.

The pen owner then used the app by hand on 2026-10-19, after that fix, and reports it
working; no per-row observation was recorded, so the rows below keep the status the
headless run gave them rather than being ticked on a summary. The cases that need a
second pen, a Bluetooth toggle, a denied permission prompt, or a forced mid-transfer
failure are left out of the acceptance for this change by decision, not because they
are expected to fail.

A later run on the same day, recorded under [Save-and-export
acceptance](#save-and-export-acceptance-add-persistence-and-deterministic-export),
exercised the durable save and deterministic export path against the same pen.

The unit suites are not a substitute for this run: they use a fake transport and
fixture frames, and nothing in them proves how the physical pen behaves. The run
also found three defects that the unit suites could not have found, all now fixed: a
two-second scan window missed the pen's bursty advertising, a completed read left the
pen connected so the next read could not find it, and a read started right after the
pen was switched on reported no pen found because the pen had not begun advertising
yet. The wait-when-nothing-is-seen window is now thirty seconds, sized for the slower
of the two switch-on delays observed; a later measurement, described under "A pen that
has just been switched on" below, found the delay to be about three seconds.

## Run record

Copy these values into the `## Gate` section of `docs/protocol-a1.md`.

| Field | Value |
| --- | --- |
| Date | 2026-10-19 |
| Host | Jamess-MacBook-Pro-M4.local |
| macOS version | 27.2 (26B5112a) |
| Xcode version | 27.1 (27A9275) |
| Pen model | `NWP-F151` |
| Pen firmware | `3.00` |
| Reported protocol version | `2.23` |
| App build | `Scripts/remote-mac-build.sh`, release configuration, `CFBundleIdentifier` `com.sushidev.neobridge.mac` |

## Running the acceptance

The menu-bar app cannot be driven from a script without an accessibility grant,
so the same binary runs one headless read attempt when
`NEOBRIDGE_ACCEPTANCE_TRACE` names a file. It builds the controller the user
interface uses, starts one read, waits for it to finish, writes a transcript of
the attempt, and exits non-zero when the read did not complete.

```bash
Scripts/remote-mac-build.sh
NEOBRIDGE_ACCEPTANCE_TRACE=/tmp/a1-run.txt \
  Apps/NeoBridgeMac/.build/bundle/NeoBridgeMac.app/Contents/MacOS/NeoBridgeMac
echo "exit=$?"
```

Run it from inside the bundle, not from a bare executable, because CoreBluetooth
reads its usage description from `Info.plist`. The exit status is 0 for a
completed read and 1 for a failed one.

The transcript is the packet log. It holds, in order:

- `outbound <hex> command=<id>` for every frame the host sent. Frames are small,
  and no outbound frame carries a device identifier: the `0x01` connection code
  is the SDK's sixteen zero bytes.
- `inbound <n> bytes` for every notification chunk, by size only. Inbound frames
  carry the pen's Bluetooth address in the version response, so no inbound
  content is written.
- `state <label>` for each lifecycle state, so the order can be compared with
  `docs/protocol-a1.md`.
- `version`, `note`, `page`, and `stroke` lines for a completed read, so the
  assembled counts can be checked against a mark and the `0xA3` summary can be
  compared with the transfer.
- `totals` and `outboundCommands`, which list every outbound command identifier
  in the order first sent. The deletion check reads the last line.

No Bluetooth addresses, serial numbers, or authentication material reach the
transcript, so it can be kept. Raw captures still belong in
`Tests/Fixtures/raw/`, which is git-ignored.

## Before the run

1. Confirm the gate in `docs/protocol-a1.md` is still open, and re-read the
   device record: the pen under test must report a protocol minor the policy
   validates.
2. Build and sign the bundle:

   ```bash
   Scripts/remote-mac-build.sh
   ```

3. Take the known mark for the test note, so the counts can be checked against
   something real: the note, the pages, and the strokes and dots you expect.
4. Write the mark **in the same note** as during the M0 capture, or take a fresh
   mark and record the counts it actually produced. Do not compare against the
   M0 capture's totals unless the page has not been used since: the pen's offline
   data only grows, so a mark is checked by its own strokes, not by a total.
5. Keep the transcript for the run, and re-read the sanitization rules in
   `AGENTS.md` before you keep any of it.

## pen-session

| Scenario | Automated coverage | The hardware run must confirm | Pass / Fail |
| --- | --- | --- | --- |
| Session runs on a fake transport | `PenSessionTests` drives the whole lifecycle over `FakePenTransport` on Linux | Not applicable to hardware; the same lifecycle runs here over CoreBluetooth | **Pass.** The same lifecycle ran over CoreBluetooth: 612 outbound frames in 3052 inbound chunks, reading one note. |
| Supported version proceeds | `PenSessionTests` proceeds to `0x21` for a validated minor | The pen's reported version is in the validated set and discovery follows | **Pass.** The pen reported `2.23`, which the policy validates, and `0x21` followed the handshake. |
| Unvalidated version is refused | `PenSessionTests` reports unsupported and sends no offline request | Not reachable with this pen unless its firmware changes; record the observed version | **Unverified.** The pen reports the validated `2.23`, so the refusal path was not reached. |
| Default connection code is rejected | `PenSessionTests` reports the rejection and tries no other code | Only reachable with a passcode-protected pen; record that this pen accepted the default | **Pass.** This pen accepted the default code: the `0x81` response carried error code zero and the session continued. |
| Initial section and owner are not established | `PenSessionTests` sends no list request when bootstrap evidence is unavailable | Not applicable: the build uses the SDK's documented wildcard | **Pass.** `0x21` carried the documented `0xffffffff` wildcard. |
| Discovered note is retrieved | `PenSessionTests` requests the discovered note with a zero page count | The command log shows `0x22` then `0x23` with `pageCnt` zero for the discovered note | **Pass.** The order was `0x01`, `0x21`, `0x22`, `0x23`; the `0x23` frame carried the identity `0x22` reported with `pageCnt` zero, then 608 acknowledgements. |
| No offline notes | `PenSessionTests` completes with zero counts and sends no `0x23` | Reachable only on an emptied pen; if not exercised, record it as unverified | **Unverified.** The pen holds note 700, so the empty-list path was not reached. |
| List data cannot be decoded | `OfflineDiscoveryTests` and `PenSessionTests` fail before `0x23` | Not reachable with a conforming pen; record it as unverified | **Unverified.** Not reachable with this pen. |
| Several notes are present | `PenSessionTests` reads each note with its own assembler | Every discovered note is read, and the app lists each one | **Unverified.** The pen lists one note (700), so the multi-note case was not reached. |
| A later note fails | `PenSessionTests` fails the sync and keeps the earlier count as diagnostic | Not reachable unless a later note is malformed; record it as unverified | **Unverified.** Only one note is present. |
| Multi-packet transfer completes | `PenSessionTests` completes a three-packet transfer | The generated mark's strokes and dots match the assembled counts | **Pass.** 608 packets assembled; page 1's first 15 strokes are the recorded mark exactly: 152 dots bounded by x 1468..3949 and y 698..892. Confirmed again on the fixed build. |
| Acknowledgement controls pacing | `ConversationPenTransport` releases one packet per acknowledged packet | The log shows one `0xA4` per `0x24`, Continue until the end packet, then Stop | **Pass.** 608 `0xA4` frames, one per `0x24`; operation `1` (Continue) through packet 607 and operation `0` (Stop) on packet 608. |
| Interrupted stream | `StalledPenTransport` and `PenSessionTests` report an incomplete transfer | Power the pen off mid-transfer: the app must show a failure, never a result | **Unverified.** The pen was not powered off mid-transfer; the adapter-loss rows below cover the reachable half. |
| Pen rejects a request | `PenSessionTests` fails on a nonzero error code | Not reachable with a conforming pen; record it as unverified | **Unverified.** Not reachable with this pen. |
| Summary differs from transfer | `PenSessionTests` uses the decoded counts when `0xA3` disagrees | The `0xA3` stroke count may lag the transfer; the app must report the decoded counts | **Pass.** One read's `0xA3` summary reported 6951 strokes while the transfer carried 6952; the app reported 6952. |
| Pen stops responding | `StalledPenTransport` fails with a timeout and the transport is closed | Force a stall by discharging the pen or moving it out of range mid-read | **Unverified.** Not forced during this run. |
| Retry after partial transfer | `PenSessionTests` starts an empty decoder and assembler on retry | Retry after a failed read and confirm the second read's counts are complete | **Unverified.** Consecutive runs after a failed run each began a new scan and read complete counts, but the in-process retry command needs the user interface. |
| Completed sync sends no deletion | `PenSessionTests` and `BluetoothPenSyncRunnerTests` find no `0x25` or `0x27` | The command log for the whole run contains no `0x25` or `0x27` | **Pass.** Every run's `outboundCommands` line lists only `0x01`, `0x21`, `0x22`, `0x23`, and `0xA4`. |
| State follows progress | `PenSessionTests` reports the states in order | The app shows scanning, connecting, verifying, and syncing before it shows a result | **Pass.** The transcript shows Scanning, Connecting, Verifying, Reading pen data, Complete, Disconnected, in that order. |
| Failure is recoverable | `PenSyncControllerTests` starts a new scan on retry without a restart | Choose **Read Pen Data** after a failure and confirm a new scan starts | **Unverified.** Needs the user interface; the controller's retry is unit tested. |

## macos-ble-transport

| Scenario | Automated coverage | The hardware run must confirm | Pass / Fail |
| --- | --- | --- | --- |
| Pen found after a power cycle | `CoreBluetoothPenTransportTests` selects by advertised name and ignores other devices | Power-cycle the pen, which changes its address, and confirm the app still finds it | **Pass.** The pen was switched off, confirmed off, and switched on again while a read was already scanning; the app found it, connected, and completed the read without any address being stored. Selection reads only the advertised name, and the app also found the pen on ten consecutive attempts without a power cycle. |
| A pen that advertises late in the window | `CoreBluetoothPenTransportTests` finds a pen whose first advertisement arrives late | The A1's own first advertisement must still land inside the window | **Pass.** The pen's first advertisement arrived up to 2.5 seconds after a scan started while it was awake. The window is thirty seconds at most, sized for a pen that has just been switched on, and every attempt after the fix found the pen. |
| A pen that has just been switched on | `CoreBluetoothPenTransportTests` asserts the window covers the powered-on delay | A read started right after the pen is switched on must wait for it rather than report it missing | **Pass, with a smaller delay than expected.** The pen was switched off, confirmed off by an on-screen prompt, and switched on again once the read's scan was already running. An independent scanner saw no advertisement for the first 6.3 seconds of its own scan, then saw the pen; the read completed (exit 0, 646 outbound frames, 7,344 strokes) and the transcript lists only the safe commands. Measured delay: the pen became visible about three seconds into the read's scan, which the old window would have covered, so this run shows the wait-and-catch behaviour rather than the need for a longer window. The window remains thirty seconds for the slower switch-on observed earlier. |
| One pen settles the scan early | `CoreBluetoothPenTransportTests` connects without waiting out the whole window | A single pen must not cost the full window on every read | **Pass.** Every read connected within two seconds of the first advertisement, well inside the thirty-second maximum. |
| No matching pen | `CoreBluetoothPenTransportTests` reports that no pen was found and stops scanning | Scan with the pen off and confirm no scan is left running | **Pass.** Observed twice with no scan left running: while the pen was silent (connected to a prior run), and once immediately after the pen was switched on, before it began advertising. Both reported no matching pen; the scan window now runs thirty seconds before it says so, and Cancel Read ends it earlier. The pen-off case was not separately forced. |
| Several matching pens | `CoreBluetoothPenTransportTests` and `PenSyncControllerTests` require an explicit choice | Reachable only with two A1 pens; if not exercised, record it as unverified | **Unverified.** Only one A1 was in range. |
| Frame split across notifications | `CoreBluetoothPenTransportTests` reassembles a frame from two chunks | A large `0x24` transfer decodes without a framing error | **Pass.** 1,335,246 inbound bytes arrived in 3,052 notification chunks and decoded with no framing error. |
| Connection failure | `CoreBluetoothPenTransportTests` reports a descriptive error and sends nothing | Put the pen in range but refuse the connection, for example by connecting another host first | **Unverified.** Not forced during this run. |
| Notification setup fails | `BluetoothPenSyncRunnerTests` fails before the version request is sent | Not reachable with a conforming pen; record it as unverified | **Unverified.** Not reachable with this pen. |
| Normal disconnect | `CoreBluetoothPenTransportTests` finishes the inbound stream without error | After a completed read, confirm the app does not report a failure when the pen powers off | **Unverified.** The pen was not powered off after a read. |
| Interrupted connection | `CoreBluetoothPenTransportTests` throws, and the session reports a failure | Move the pen out of range mid-transfer and confirm the app reports a failure | **Unverified.** The pen was not moved mid-transfer. |
| Permission denied | `CoreBluetoothPenTransportTests` reports that permission is required and does not scan | Deny the Bluetooth prompt, and confirm the app neither scans nor turns on the radio | **Unverified.** Access was granted; a denial needs the system prompt and the user interface. |
| Permission granted | The adapter state gate is unit tested | Grant the prompt and confirm the scan starts | **Pass.** The app scanned and connected, which requires granted access. |
| Adapter not ready before a scan | `CoreBluetoothPenTransportTests` reports the adapter state and does not scan | Switch Bluetooth off, choose **Read Pen Data**, and confirm the app reports that Bluetooth is off without scanning | **Unverified.** Bluetooth was not switched off. |
| Adapter stops being ready mid-scan | `CoreBluetoothPenTransportTests` reports the adapter state instead of a missing pen | Start a read, switch Bluetooth off during the scan, and confirm the app reports the adapter state rather than a missing pen | **Unverified.** Bluetooth was not switched off. |
| Adapter stops being ready during the connection setup | The state cache and the pending-waiter failures are covered by reading, not by a unit test, because instantiating a real `CBCentralManager` needs a radio | With a pen in range, choose **Read Pen Data**, switch Bluetooth off as the connection starts, and confirm the app reports the adapter state and never begins the handshake | **Unverified.** Bluetooth was not switched off. |
| Adapter never answers | `BluetoothPenSyncRunnerTests` fails an attempt whose connection never returns with a setup timeout | Not reachable deliberately; record it as unverified unless a stalled connection is observed | **Unverified.** No stalled connection was observed. |
| Bluetooth state has not resolved when a read starts | `CoreBluetoothPenTransportTests` waits for the state and then scans | A read started right after launch must scan rather than report an unknown state | **Pass.** The first headless attempt reported "the Bluetooth state is not known yet", which is this window on real hardware; the wait was added for it, and every later attempt scanned. |
| Bluetooth state never resolves | `CoreBluetoothPenTransportTests` reports the state without scanning | Not reachable while the adapter answers; record it as unverified | **Unverified.** The state resolved on every attempt. |
| Completed read releases the pen | `BluetoothPenSyncRunnerTests` asserts the transport is closed after a completed read | Four consecutive reads must each find the pen advertising again | **Pass.** Every completed read logged Disconnected, and both the four consecutive reads before the fixes and three consecutive reads after them each found the pen advertising again. |
| Failed read releases the pen | `BluetoothPenSyncRunnerTests` and `PenSessionTests` close the transport on a failure | A read that fails after connecting must not leave the pen attached | **Unverified.** The failures observed during this run were scan failures, before any connection. |

## macos-app-shell

These rows need the user interface, which the headless acceptance mode does not
drive. The values it does check are recorded in the rows where they appear.

The interface was used by hand on 2026-10-19 and reported working, but no per-row
observation was written down, so these rows stay unverified. Ticking them needs a run
with the interface in hand and one note per row, not a summary judgement.

| Scenario | Automated coverage | The hardware run must confirm | Pass / Fail |
| --- | --- | --- | --- |
| Launch as a menu-bar app | The bundle carries `LSUIElement`, checked by `Scripts/remote-mac-build.sh` | The app has no Dock icon and its menu-bar item is present after launch | **Pass.** The assembled bundle launched as an accessory process with no Dock icon. |
| Open the details window | The window scene is declared; the command is listed in `Apps/NeoBridgeMac/README.md` | Choosing **Connection Details…** opens the window, and closing it leaves the app running | **Pass for the recorded cases.** First use on 2026-10-19 reported that the command appeared to do nothing. A window probe (`CGWindowListCopyWindowInfo`) showed the window existed on screen at layer 0, 480x460, with the app inactive: an accessory app is not activated by creating a window, so it was built behind the frontmost app. The command now takes activation instead of requesting it, and the window makes itself key. Verified by recording the window order across four commands: (1) window created, (2) minimized then restored from the Dock, (3) window open with another app frontmost, (4) minimized and restored again. Every command ended with the app active and its window the frontmost window; before the fix, the restore case never activated. An isolated probe app showed why: with another app frontmost, `activate()` is declined with the window visible, minimized, or mid-restore, while `activate(ignoringOtherApps:)` is granted in all three. A window left on another Space or display was not covered: neither activation nor ordering moves a window between Spaces. |
| Show sync results | `PenSyncControllerTests` publishes the counts and the notes read | The counts match the mark, and the note list names the note that was read | **Unverified.** Needs the user interface. The headless run confirmed the same values: 6952 strokes, 70679 dots, 19 pages, and note 700 read. |
| Show progress during sync | `PenSyncControllerTests` publishes each in-progress state | Counts from an earlier read disappear while a new read runs | **Unverified.** Needs the user interface. |
| Failed transfer has partial data | `PenSyncControllerTests` presents the failure and no result | After a forced mid-transfer failure, no counts appear as a completed result | **Unverified.** Needs the user interface and a forced failure. |
| Retry after disconnect | `PenSyncControllerTests` builds a new runner for the retry | Retry after a dropped connection starts a new scan without a restart | **Unverified.** Needs the user interface. |
| Cancel an active sync | `PenSyncControllerTests` returns to idle without a result | **Cancel** stops the scan or read and returns to idle, with no completion notice | **Unverified.** Needs the user interface. |
| Completed sync is labelled unsaved | `PenSyncControllerTests` checks the notice text | The completed view states that nothing was written to disk or exported | **Unverified.** Needs the user interface. |
| Read action is labelled clearly | `PenSyncControllerTests` checks the action title | The command reads **Read Pen Data** and never implies an import or an export | **Unverified.** Needs the user interface. |

## Save-and-export acceptance (add-persistence-and-deterministic-export)

The durable save and deterministic export this change adds needs the same physical
A1, driven by the same headless mode with `NEOBRIDGE_EXPORT_DIRECTORY` also set, so
the read commits to the library and publishes files in one attempt:

```bash
Scripts/remote-mac-build.sh
NEOBRIDGE_ACCEPTANCE_TRACE=/tmp/a1-run.txt \
NEOBRIDGE_EXPORT_DIRECTORY=/tmp/a1-export \
  Apps/NeoBridgeMac/.build/bundle/NeoBridgeMac.app/Contents/MacOS/NeoBridgeMac
echo "exit=$?"
```

Run record:

| Field | Value |
| --- | --- |
| Date | 2026-10-19 |
| Host | Jamess-MacBook-Pro-M4.local |
| macOS version | 27.2 (26B5112a) |
| Xcode version | 27.1 (27A9275) |
| Pen model | `NWP-F151` |
| Pen firmware | `3.00` |
| Reported protocol version | `2.23` |
| App build | `Scripts/remote-mac-build.sh`, release configuration |
| Transcript | sanitized packet log, 12,355 lines; no Bluetooth address, serial number, or authentication material |

The run read note 700, section 3, owner 27 across 22 pages: 8064 strokes and 82238
dots in 711 outbound frames and 3547 inbound chunks. It committed 8064 strokes to the
library and published 66 files (22 pages times JSON, SVG, and Markdown). The exit
status was 0.

| Scenario | Automated coverage | The hardware run must confirm | Pass / Fail |
| --- | --- | --- | --- |
| Repeated offline transfer | `PenLibraryImporterTests`, `SQLitePenLibraryTests` | A second read of the same note adds no duplicate reliable strokes | **Pass.** The batch added 2 strokes and reported 8062 duplicates, so the 8062 strokes already stored from the earlier hand-run were not re-added. |
| Verified durable import is reported | `PenLibraryImporterTests` | A completed read states that the library save succeeded and names the export destination | **Pass, for the notice text.** The notice read: "Saved 8064 strokes across 22 pages to the library. Wrote 66 files to <destination>." |
| Complete transfer contains no strokes | `PenLibraryImporterTests` | Reachable only against an emptied pen; record as unverified | **Unverified.** The pen holds note 700. |
| Export a stored page | `FilePublicationTests` | Every non-empty page produces one JSON, one SVG, and one Markdown file | **Pass.** 66 files: 22 of each format, for pages 1 and 16 through 36. |
| Deterministic bytes | `PageExportGoldenTests` | Byte-for-byte equality of a re-export | **Not exercised on hardware.** The destination was a fresh directory, so no target was pre-existing; byte equality across order, source, and restart is covered by the golden tests. |
| Fixed page canvas | `PageExportGoldenTests` | Every page's SVG declares the same canvas and origin | **Pass.** All 22 SVGs declare `viewBox="0 0 54.84 88.58"`, `width="130.0mm"`, and `height="210.0mm"`. |
| Complete file publication | `FilePublicationTests` | Every target is reported published or failed, and no file on disk is partial | **Pass.** All 66 targets reported `published`, none failed; every JSON file parsed and every SVG file was well-formed. |
| Preserve existing destination files | `FilePublicationTests` | Reachable only when a target already differs; record as unverified | **Unverified.** The run used a fresh export directory, so no target was replaced and no backup was built. |
| Export content is inspected for device secrets | `NeoExportTests`, `Tests/Integration` | No exported file contains a Bluetooth address, serial number, or authentication material | **Pass.** A scan of all 66 files found no pen model, firmware, serial number, Bluetooth address, or `NWP-F151` string. |
| Successful import | `PenSessionTests`, `BluetoothPenSyncRunnerTests` | The pen's strokes remain on the pen and no deletion request is sent | **Pass.** The transcript's `outboundCommands` line lists only `0x01`, `0x21`, `0x22`, `0x23`, and `0xA4` (707 acknowledgements); no `0x25` or `0x27` appears anywhere in the transcript. |

## After the run

1. Tick each row that passed and record the observed value for the rows that
   need one. Rows that could not be reached stay unchecked with a note saying
   why, rather than being marked as passed.
2. Record the run in the `## Gate` section of `docs/protocol-a1.md`: the date,
   host, OS, pen firmware, and protocol version, plus which rows were not
   reached.
3. Confirm cleanup stayed on the pen:

   ```bash
   grep -rn "deletionEnabled" Packages/NeoCore/Sources/NeoCore
   ```

   `PenCleanupPolicy.deletionEnabled` must still be `false`, and the command log
   must contain no `0x25` or `0x27`.
4. If a row failed, leave it unchecked and record the failure. Do not archive
   the change while a row that the change depends on is failing.
