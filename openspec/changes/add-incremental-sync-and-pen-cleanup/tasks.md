# Tasks

## 1. Transfer option experiment

- [x] 1.1 Establish known existing stroke identities on note 700, section 3, owner 27, add known new strokes, and read with `notNextTransfer`. Record stroke, dot, and page counts, identities, outbound bytes, final packet, acknowledgements, and sanitized transcript path. Verify the `0x23` option byte is `0x00` and compare the results with the 8062-stroke baseline.
  - **Ran 2026-10-19.** The known-old set was the whole pen: 8,087 identities across 22 pages of note 700, section 3, owner 27, every one of them present in the library snapshot `library-before-mark.sqlite`. Five strokes were then written on page 1 by hand as the known-new set. The `notNextTransfer` read (`opt00-a`) sent the option byte `0x00`, received the 15-byte `0xA3` summary, and then received no `0x24` packet at all: 4 outbound frames totalling 93 bytes, 5 inbound chunks, 0 strokes, no final packet and no acknowledgement. It failed as a timeout, and afterwards the pen answered no further `0x23` request for either option until it was switched off and on again. Compared with the earlier reads, which returned all 8,062 already-stored strokes, this option returns nothing at all.
- [x] 1.2 Repeat the same known-old and known-new experiment with `nextAndReserve`, then repeat a completed read with each option. Verify the returned stroke identities reveal whether either option advances a cursor without losing new strokes, and that both `0x23` option bytes are recorded.
  - **Ran 2026-10-19.** `nextAndReserve` (`opt02-a`, `opt02-b`) returned 8,092 strokes and 84,138 dots across 22 pages in 718 `0x24` packets, with 718 acknowledgements, a final packet of 718, and operation Stop. The repeat returned the same 8,092 identities byte-for-byte; the import added 5 strokes on the first read and 0 on the repeat. Both option bytes are recorded: `0x00` in `opt00-a` and `opt00-abort`, `0x02` in the four `opt02` runs, each on the transcript's `run` line and in the framed `0x23` hex. Neither option advances a cursor, so no read returns only the new strokes.
- [x] 1.3 For each candidate option, disconnect before the final `0x24` packet and re-read with a known safe option. Verify every stroke that was not durably imported remains retrievable, and record both transcripts and identity comparisons.
  - **Ran 2026-10-19** with `NEOBRIDGE_ACCEPTANCE_ABORT_AT_PACKET`. `nextAndReserve` with the interrupt armed at packet 100 (`opt02-abort`) failed after 99 assembled packets without an end packet; the recovery read (`opt02-abort-recovery`) returned all 8,092 identities, including the 5 that no read had imported, identical to `opt02-a`. For `notNextTransfer` the interrupt is unreachable because no packet ever arrives: `opt00-abort` is identical to `opt00-a`, and its recovery read (`opt00-abort-recovery`) returned all 8,092 identities. Both transcript pairs and the identity comparison are archived under `Tests/Fixtures/raw/acceptance-2026-10-19-transfer-option/`.
- [x] 1.4 Record which option, if any, returns exactly the known new strokes without making old or new strokes inaccessible, in `docs/protocol-a1.md`. Verify the section names both options, counts, identities, completed and interrupted outcomes, and cites sanitized transcripts.
  - **Recorded 2026-10-19** in the "Incremental transfer experiment, 2026-10-19" section of `docs/protocol-a1.md`. It names both options and their bytes, the counts and identities of every run, the completed and interrupted outcomes, the run record, and the archived sanitized transcripts. Conclusion: no option is incremental; `nextAndReserve` remains the only option with completed-transfer evidence, and `notNextTransfer` may not be sent.
- [x] 1.5 Pin both request frames with tests, using sanitized bytes rather than a captured transcript. Verify `(cd Packages/NeoProtocol && swift test)` passes and asserts the option byte for each value, including that `nextAndDelete` is not the default.

## 2. Adopt the transfer option

- [x] 2.1 Set the option `PenRequest.offlineData(for:)` sends to the one task 1.4 establishes as safe and incremental. If none is incremental, use the current option only if its non-destructive behavior is established; otherwise report offline retrieval as unsupported. Verify a `PenSession` test over `FakePenTransport` asserts the chosen byte or refusal to send `0x23`.
  - No option is established as incremental, so the current `nextAndReserve` (`0x02`) is kept because both physical reads observed it as non-destructive. `PenSessionTests.testSessionSendsTheEstablishedNonDestructiveTransferOption` asserts the byte.
- [x] 2.2 Prevent the read path from ever sending a deleting option. Verify a test asserts that no value the session can send is `nextAndDelete`, and that the type offers no route to it from `offlineData(for:)`.
  - `PenRequest.offlineData(for:)` accepts only `OfflineReadTransferOption`, which has no deleting member. `PenSessionTests.testTheDeletingOptionIsNotTheDefaultAndIsUnreachableFromTheReadPath` covers it.
- [x] 2.3 Document the chosen option, the rejected one, and the trace behind the choice in the `Packages/NeoProtocol` doc comments. Verify the doc comment names the option and the experiment it came from.
- [x] 2.4 Confirm the whole portable suite still passes on Linux after the change. Verify `(cd Packages/NeoProtocol && swift test)` and `(cd Packages/NeoStorage && swift test)` both pass.
  - `Scripts/test-portable.sh` prints PASSED (see 6.1).

## 3. Gate the deletion commands on evidence

- [ ] 3.1 Trace the `0x25` and `0x27` request payloads and `0xA5` and `0xA7` responses against a physical A1. Record framed bytes, whether each response means acceptance or completed removal, and sanitized fixtures. Leave unchecked if no pen is available.
  - **Blocked:** needs a physical A1. The commands stay gated.
- [ ] 3.2 Test each deletion command's scope with verified old strokes and newer unverified strokes on the same page or note. Re-read afterward and prove that only the exact verified data was removed; leave any command whose scope cannot be proven disabled. Leave unchecked if no pen is available.
  - **Blocked:** needs a physical A1. Both commands stay disabled.
- [x] 3.3 Trace an interrupted transfer: disconnect before the final packet, then re-read and compare known stroke identities with the pre-transfer set. Verify no uncommitted stroke became inaccessible. Leave unchecked if no pen is available.
  - **Ran 2026-10-19** as part of the transfer-option experiment. `opt02-abort` interrupted a `nextAndReserve` read after 99 packets; `opt02-abort-recovery` then returned all 8,092 identities, identical to a completed read, including the 5 that no read had imported. The `0x00` case cannot be interrupted because it sends no packet; its recovery read also returned all 8,092 identities. Both transcript pairs are archived under `Tests/Fixtures/raw/acceptance-2026-10-19-transfer-option/`, and the gate condition row in `docs/protocol-a1.md` cites this trace. The `PenDeletionEvidence` verdicts are left as the change recorded them: the three untraced conditions and the command scope keep both deletion commands gated, so recording the retention verdict stays a deliberate step.
- [x] 3.4 Derive `deletionEnabled` from explicit safe verdicts for payload framing, exact deletion scope, response meaning, and interrupted-transfer retention, not trace existence alone. Verify tests keep the gate closed for absent or unsafe verdicts and prevent `0x25`/`0x27` while closed.
- [x] 3.5 Move only commands with established safe verdicts from blocked to gated in `CommandEvidence`. Verify evidence-table tests assert each command's level and refuse unauthorized commands.
- [x] 3.6 Document every gate condition and its pending, safe, or unsafe verdict in `docs/protocol-a1.md`, citing the sanitized physical traces.
  - No deletion trace exists, so the section records every condition as `pending` and states that no trace is cited for any of them.

## 4. Journaled deletion after confirmed storage

- [x] 4.1 Send deletion only for the exact proven scope of a completed transfer after durable import and successful publication of every requested export. Verify a storage test records that scope as `.prepared` then `.requested` before sending and sends nothing for an uncommitted batch or failed or pending export.
- [x] 4.2 Promote `.requested` to `.confirmed` only on a matching response whose physical trace proves removal of the recorded scope. Verify tests assert a mismatch or timeout leaves it outstanding.
- [x] 4.3 Do not repeat an outstanding request automatically. Verify a second sync re-reads safely, compares the recorded scope with the durable library, resolves only an unambiguous outcome, and never deletes newly written or unverified strokes.
- [x] 4.4 Add fake-transport integration scenarios for default cleanup after verified import and export, no deletion after an interrupted transfer or failed export, retention by choice, and cleanup of an earlier published note when a later note fails only if the scopes do not overlap. Verify `(cd Tests/Integration && swift test)` passes on Linux.
- [x] 4.5 Document the ordering rule and the journal states in the `Packages/NeoStorage` and `Packages/NeoCore` doc comments. Verify each doc comment names the ordering rule and the states.

## 5. Default cleanup and retention choice in the app

- [x] 5.1 Show before transfer that cleanup is the intended default after verified import and export, and offer retention for that sync. Verify an app test checks the presented default and retention choice.
- [x] 5.2 Make retention apply only to the current sync. Verify a later sync again presents default cleanup and that choosing retention sends no deletion.
- [x] 5.3 Report whether the pen's copy was retained by choice, reclaimed, skipped with a stated blocking condition, or left outstanding. Verify app tests cover all four outcomes.
- [x] 5.4 Keep deletion unavailable while the evidence gate is closed, but permit the sync to retain data and explain why cleanup was skipped. Verify an app test checks both conditions.
- [x] 5.5 Document default cleanup, retention choice, gate behavior, and outcome reporting in `Apps/NeoBridgeMac/README.md`. Verify the documented steps match the built menu.

## 6. Integrated verification

- [x] 6.1 Run the portable verification entry point. Verify `Scripts/test-portable.sh` prints PASSED, including the portability-boundary check.
- [x] 6.2 Build the app through the remote Mac entry point with the Xcode gate enabled. Verify `Scripts/remote-mac-build.sh` passes with the gate and assembles the bundle.
- [ ] 6.3 Run physical A1 acceptance with default cleanup and a sanitized transcript, confirming the targeted deletion command, its response meaning, and readable library and published export copies. Verify before-and-after stroke identities, including newer unverified strokes on the same page or note. Leave unchecked while the gate is closed.
  - **Blocked:** the gate is closed, so no deletion command is reachable. `Tests/Hardware/README.md` carries the rows as unverified.
- [x] 6.4 Confirm the retaining mode still sends no deletion through the whole stack. Verify a headless run's `outboundCommands` line contains no `0x25` or `0x27`.
  - **Ran 2026-10-19.** The retaining run recorded `cleanup=keepOnPen` on its `run` line, read 8,092 strokes and 84,138 dots across 22 pages, imported 0 duplicates, and published its export. Its `outboundCommands` line lists only `0x01`, `0x04`, `0x21`, `0x22`, `0x23`, and `0xA4`; `grep -c` for `0x25` or `0x27` over the transcript is 0.

## Workflow follow-up

- Archive `add-persistence-and-deterministic-export` first: it introduces the `stroke-library` capability this change modifies, and archiving this delta before it fails with "target spec does not exist".
- Record the experiment result in the knowledge base so the transfer-option question is not reopened.
  - The question is answered in `docs/protocol-a1.md`: no option is incremental, `nextAndReserve` is the only option with completed-transfer evidence, `notNextTransfer` transfers nothing and wedges the pen, the pinned bytes are `0x00` and `0x02`, and the deleting option is unreachable. The vault entry still says the question is open; it needs updating the next time the knowledge-base tools are available.
- Archive this change once the portable suites and the Mac gate pass.
