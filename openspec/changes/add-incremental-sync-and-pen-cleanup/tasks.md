# Tasks

## 1. Transfer option experiment

- [ ] 1.1 Establish known existing stroke identities on note 700, section 3, owner 27, add known new strokes, and read with `notNextTransfer`. Record stroke, dot, and page counts, identities, outbound bytes, final packet, acknowledgements, and sanitized transcript path. Verify the `0x23` option byte is `0x00` and compare the results with the 8062-stroke baseline.
- [ ] 1.2 Repeat the same known-old and known-new experiment with `nextAndReserve`, then repeat a completed read with each option. Verify the returned stroke identities reveal whether either option advances a cursor without losing new strokes, and that both `0x23` option bytes are recorded.
- [ ] 1.3 For each candidate option, disconnect before the final `0x24` packet and re-read with a known safe option. Verify every stroke that was not durably imported remains retrievable, and record both transcripts and identity comparisons.
- [ ] 1.4 Record which option, if any, returns exactly the known new strokes without making old or new strokes inaccessible, in `docs/protocol-a1.md`. Verify the section names both options, counts, identities, completed and interrupted outcomes, and cites sanitized transcripts.
- [ ] 1.5 Pin both request frames with tests, using sanitized bytes rather than a captured transcript. Verify `(cd Packages/NeoProtocol && swift test)` passes and asserts the option byte for each value, including that `nextAndDelete` is not the default.

## 2. Adopt the transfer option

- [ ] 2.1 Set the option `PenRequest.offlineData(for:)` sends to the one task 1.4 establishes as safe and incremental. If none is incremental, use the current option only if its non-destructive behavior is established; otherwise report offline retrieval as unsupported. Verify a `PenSession` test over `FakePenTransport` asserts the chosen byte or refusal to send `0x23`.
- [ ] 2.2 Prevent the read path from ever sending a deleting option. Verify a test asserts that no value the session can send is `nextAndDelete`, and that the type offers no route to it from `offlineData(for:)`.
- [ ] 2.3 Document the chosen option, the rejected one, and the trace behind the choice in the `Packages/NeoProtocol` doc comments. Verify the doc comment names the option and the experiment it came from.
- [ ] 2.4 Confirm the whole portable suite still passes on Linux after the change. Verify `(cd Packages/NeoProtocol && swift test)` and `(cd Packages/NeoStorage && swift test)` both pass.

## 3. Gate the deletion commands on evidence

- [ ] 3.1 Trace the `0x25` and `0x27` request payloads and `0xA5` and `0xA7` responses against a physical A1. Record framed bytes, whether each response means acceptance or completed removal, and sanitized fixtures. Leave unchecked if no pen is available.
- [ ] 3.2 Test each deletion command's scope with verified old strokes and newer unverified strokes on the same page or note. Re-read afterward and prove that only the exact verified data was removed; leave any command whose scope cannot be proven disabled. Leave unchecked if no pen is available.
- [ ] 3.3 Trace an interrupted transfer: disconnect before the final packet, then re-read and compare known stroke identities with the pre-transfer set. Verify no uncommitted stroke became inaccessible. Leave unchecked if no pen is available.
- [ ] 3.4 Derive `deletionEnabled` from explicit safe verdicts for payload framing, exact deletion scope, response meaning, and interrupted-transfer retention, not trace existence alone. Verify tests keep the gate closed for absent or unsafe verdicts and prevent `0x25`/`0x27` while closed.
- [ ] 3.5 Move only commands with established safe verdicts from blocked to gated in `CommandEvidence`. Verify evidence-table tests assert each command's level and refuse unauthorized commands.
- [ ] 3.6 Document every gate condition and its pending, safe, or unsafe verdict in `docs/protocol-a1.md`, citing the sanitized physical traces.

## 4. Journaled deletion after confirmed storage

- [ ] 4.1 Send deletion only for the exact proven scope of a completed transfer after durable import and successful publication of every requested export. Verify a storage test records that scope as `.prepared` then `.requested` before sending and sends nothing for an uncommitted batch or failed or pending export.
- [ ] 4.2 Promote `.requested` to `.confirmed` only on a matching response whose physical trace proves removal of the recorded scope. Verify tests assert a mismatch or timeout leaves it outstanding.
- [ ] 4.3 Do not repeat an outstanding request automatically. Verify a second sync re-reads safely, compares the recorded scope with the durable library, resolves only an unambiguous outcome, and never deletes newly written or unverified strokes.
- [ ] 4.4 Add fake-transport integration scenarios for default cleanup after verified import and export, no deletion after an interrupted transfer or failed export, retention by choice, and cleanup of an earlier published note when a later note fails only if the scopes do not overlap. Verify `(cd Tests/Integration && swift test)` passes on Linux.
- [ ] 4.5 Document the ordering rule and the journal states in the `Packages/NeoStorage` and `Packages/NeoCore` doc comments. Verify each doc comment names the ordering rule and the states.

## 5. Default cleanup and retention choice in the app

- [ ] 5.1 Show before transfer that cleanup is the intended default after verified import and export, and offer retention for that sync. Verify an app test checks the presented default and retention choice.
- [ ] 5.2 Make retention apply only to the current sync. Verify a later sync again presents default cleanup and that choosing retention sends no deletion.
- [ ] 5.3 Report whether the pen's copy was retained by choice, reclaimed, skipped with a stated blocking condition, or left outstanding. Verify app tests cover all four outcomes.
- [ ] 5.4 Keep deletion unavailable while the evidence gate is closed, but permit the sync to retain data and explain why cleanup was skipped. Verify an app test checks both conditions.
- [ ] 5.5 Document default cleanup, retention choice, gate behavior, and outcome reporting in `Apps/NeoBridgeMac/README.md`. Verify the documented steps match the built menu.

## 6. Integrated verification

- [ ] 6.1 Run the portable verification entry point. Verify `Scripts/test-portable.sh` prints PASSED, including the portability-boundary check.
- [ ] 6.2 Build the app through the remote Mac entry point with the Xcode gate enabled. Verify `Scripts/remote-mac-build.sh` passes with the gate and assembles the bundle.
- [ ] 6.3 Run physical A1 acceptance with default cleanup and a sanitized transcript, confirming the targeted deletion command, its response meaning, and readable library and published export copies. Verify before-and-after stroke identities, including newer unverified strokes on the same page or note. Leave unchecked while the gate is closed.
- [ ] 6.4 Confirm the retaining mode still sends no deletion through the whole stack. Verify a headless run's `outboundCommands` line contains no `0x25` or `0x27`.

## Workflow follow-up

- Archive `add-persistence-and-deterministic-export` first: it introduces the `stroke-library` capability this change modifies, and archiving this delta before it fails with "target spec does not exist".
- Record the experiment result in the knowledge base so the transfer-option question is not reopened.
- Archive this change once the portable suites and the Mac gate pass.
