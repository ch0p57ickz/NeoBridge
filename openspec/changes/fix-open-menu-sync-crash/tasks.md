# Tasks

## 1. Reproduce and isolate the menu recursion

- [x] 1.1 Confirm the Sync Now code path and assembled menu are available without requiring its remaining acceptance tasks to be complete, verify the existing physical A1 M0 read evidence in `docs/protocol-a1.md`, and record the three crash reports' shared exception and open-menu stack in investigation notes; verify the UI-focused scope before changing the menu.
- [x] 1.2 On a logged-in macOS 27.2 GUI session without a compatible pen, select Sync Now and reopen the menu during scanning, then compare with a closed-menu run; verify the observed Syncing-to-Not Detected sequence, OS/build, crash or survival, and sanitized log or report are recorded without pen identifiers.
- [x] 1.3 Compare targeted SwiftUI menu variants with the baseline and the native-menu candidate on the same Mac GUI; record observed attempts and failures, identify the implicated update boundary, and avoid claiming that one SwiftUI expression is proven responsible.

## 2. Correct menu presentation and cover state transitions

- [x] 2.1 Implement the evidence-backed menu presentation change without changing read scheduling or cleanup authorization; verify the menu remains usable and shows the correct single status line and applicable controls during the reproduced open-menu read.
- [x] 2.2 Add focused menu-facing controller tests for start, progress, completion, failure, cancel, elapsed result, and changing command availability; verify the relevant `NeoBridgeMacCore` XCTest suite passes and covers any changed presentation mapping.
- [x] 2.3 Update the menu documentation and Mac acceptance checklist with the no-pen Sync Now reproduction, expected status and control behavior, the reopen sequence, and the separate physical-A1 read; verify the documented no-pen sequence can be followed with the assembled app and distinguishes background updates from command selection that dismisses the menu.

## 3. Verify the integrated app

- [x] 3.1 Run `Scripts/test-portable.sh` and the existing fake-transport integration scenarios for offline import, replay deduplication, interruption, and recovery; verify they pass and no Apple framework enters the portable packages.
- [x] 3.2 Run `Scripts/remote-mac-build.sh` with its Xcode gate and test the assembled app in the GUI through repeated no-pen Sync Now scans with the menu reopened during each scan, including a Not Detected result, a failure/cancel path, and a command selection afterward; verify the app remains running, status and controls match each state, the command acts normally, and the build reports PASSED.
- [ ] 3.3 With a physical A1, run one automatic Sync and Retain read with the menu open through completion and an elapsed-time status update; then select Sync Now and reopen the menu during its read. Verify the app remains running, reads finish, status and controls stay accurate, no deletion command or deleting transfer is requested, and any pen-traffic transcript is sanitized. Leave this task unchecked with a hardware or GUI-runner blocker note if acceptance cannot be run.

Verification note (2026-10-22, macOS 27.2 build 26B118): the SwiftUI baseline crashed on cycle 6 of the short open-menu no-pen probe with the same recursion signature. Static content survived an exploratory probe; several live-content variants crashed, so no individual SwiftUI expression was isolated. The native menu remained running through two no-pen probe cycles (one Failed, one Not Detected). The probe parser incorrectly labeled both cycles timeout because it kept a menu-item prefix; the captured status sequences still showed the settled states. With the A1 powered on and Sync and Retain checked, one direct Sync Now run showed Syncing with Cancel Read and disabled Sync Now, then Synced with Sync Now enabled while the menu remained open. The app XCTest suite passed 187 tests; the Xcode-gated build and portable tests reported PASSED. The physical A1 task remains unchecked because a sanitized traffic transcript and explicit automatic-read observation were not captured.
