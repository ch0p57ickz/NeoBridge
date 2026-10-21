import Foundation
import NeoBridgeMacCore
import NeoCore
import NeoExport
import NeoProtocol
import XCTest

/// Tests for the shell's state machine, driven by stubbed runners and a real
/// durable library.
///
/// Every test uses ``StubPenSyncRunner``, so the shell's presentation is checked
/// without a radio and without a pen. The library is a real SQLite store in a
/// temporary directory, so a completed read is committed and its files are
/// published exactly as they would be on a real device.
@MainActor
final class PenSyncControllerTests: XCTestCase {
    private let penName = CoreBluetoothPenTransport.advertisedName

    // MARK: - Progress

    func testPresentsEachInProgressStage() async throws {
        let library = try makeLibrary()
        defer { library.remove() }

        for stage in [PenSyncStage.scanning, .connecting, .verifying, .syncing] {
            let controller = makeController(
                library: library.importer,
                destination: library.destination,
                stages: [stage],
                outcome: .waitsForCancellation
            )

            controller.readPenData()
            try await waitUntil(controller, is: PenSyncController.Phase(stage))

            XCTAssertTrue(controller.isBusy)
            XCTAssertNil(controller.outcome)

            controller.cancel()
            XCTAssertEqual(controller.phase, .idle)
        }
    }

    func testPresentsSavingThenExportingThenComplete() async throws {
        let save = PenLibrarySave(
            batchID: UUID(),
            pages: [TestRead.page],
            insertion: PenStrokeInsertion(addedStrokeCount: 1, duplicateStrokeCount: 0),
            strokeCount: 1,
            dotCount: 1
        )
        let report = PenExportReport(
            artifacts: [
                PenExportArtifact(
                    format: .json,
                    path: "/tmp/ncode-s3-o27-b700-p1.json",
                    byteCount: 12,
                    status: .published
                )
            ]
        )
        let coordinator = StubImportCoordinator(outcome: .saved(save, export: report))
        let destination = FixedExportDestination(directory: FileManager.default.temporaryDirectory.path)
        let controller = makeController(
            library: coordinator,
            destination: destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        controller.readPenData()
        try await waitUntil(controller, is: .saving)

        // Saving and exporting are separate steps, so the shell can say which one
        // it is doing rather than showing one vague "syncing" state.
        XCTAssertTrue(controller.isBusy)
        XCTAssertEqual(controller.statusLabel, "Saving to the library")
        XCTAssertNil(controller.outcome)

        await coordinator.saving.open()
        try await waitUntil(controller, is: .exporting)
        XCTAssertEqual(controller.statusLabel, "Writing export files")

        await coordinator.exporting.open()
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(outcome.exportSucceeded)
        XCTAssertEqual(controller.statusLabel, "Complete")
    }

    func testShowsTheFinalCountsAfterACompleteRead() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            stages: [.scanning, .connecting, .verifying, .syncing],
            outcome: .success(TestRead.twelveStrokeResult())
        )

        controller.readPenData()
        XCTAssertEqual(controller.phase, .scanning, "progress must be visible before the first await")
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertEqual(outcome.summary.strokeCount, 12)
        XCTAssertEqual(outcome.summary.dotCount, 240)
        XCTAssertEqual(outcome.summary.distinctPageCount, 3)
        XCTAssertEqual(outcome.summary.notes.map(\.label), ["Note 700 · section 3 · owner 27"])
        XCTAssertFalse(controller.isBusy)
    }

    func testPenStateBelongsToTheCurrentCompletedRead() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        var payload = [UInt8](repeating: 0, count: 64)
        payload[15] = 10
        payload[20] = 0x80 | 94
        let measured = try XCTUnwrap(PenState(payload: payload))
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()], penState: measured))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)
        XCTAssertEqual(controller.penState, measured)
        XCTAssertEqual(controller.outcome?.penState, measured)

        controller.readPenData()
        XCTAssertNil(controller.penState, "the previous reading is not current during a new read")
        controller.cancel()
    }

    // MARK: - Save and export

    func testCompleteReadSavesStrokesAndWritesEveryFormat() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke(), TestRead.stroke(x: 20)]))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(outcome.isSaved, "a completed read is committed to the library")
        XCTAssertEqual(outcome.save?.strokeCount, 2)
        XCTAssertEqual(outcome.save?.pages, [TestRead.page])
        XCTAssertEqual(outcome.save?.insertion.addedStrokeCount, 2)

        // Every format is published for the page, so the per-file result names
        // all three rather than one whole-set success.
        XCTAssertTrue(outcome.exportSucceeded)
        let artifacts = try XCTUnwrap(outcome.export?.artifacts)
        XCTAssertEqual(Set(artifacts.map(\.format)), Set(PenExportFormat.allCases))
        XCTAssertTrue(artifacts.allSatisfy(\.didPublish))
        XCTAssertEqual(
            try library.exportedFiles(),
            [
                "ncode-s3-o27-b700-p1.json",
                "ncode-s3-o27-b700-p1.md",
                "ncode-s3-o27-b700-p1.svg",
            ]
        )

        XCTAssertTrue(outcome.notice.contains("Saved 2 strokes"))
        XCTAssertTrue(outcome.notice.contains("Wrote 3 files"))
    }

    func testSavedStrokesAreReadBackFromTheLibrary() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke(), TestRead.stroke(x: 20)]))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        // The shell reports a save; the durable rows are what a later export or
        // viewer reads, so the two must agree.
        let stored = try await library.library.strokes(on: TestRead.page)
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.flatMap(\.points).map(\.x), [10, 20])
    }

    func testExportFailureIsReportedPerFileAndCanBeRetried() async throws {
        let library = try makeLibrary(
            publisher: StubPenExportPublisher(failures: [.svg: "the disk is full"])
        )
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke(), TestRead.stroke(x: 20)]))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        let first = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(first.isSaved, "a failed file must not undo the saved read")
        XCTAssertTrue(first.exportFailed)
        XCTAssertEqual(first.export?.failed.count, 1)
        XCTAssertEqual(first.export?.failed.first?.format, .svg)
        XCTAssertEqual(first.export?.failureMessages, ["the disk is full"])
        XCTAssertTrue(controller.canRetryExport)
        XCTAssertFalse(try library.exportedFiles().contains("ncode-s3-o27-b700-p1.svg"))

        controller.retryExport()
        try await waitForAttemptToSettle(controller)

        let second = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(second.exportSucceeded)
        XCTAssertTrue(try library.exportedFiles().contains("ncode-s3-o27-b700-p1.svg"))
        XCTAssertEqual(second.save?.batchID, first.save?.batchID, "a retry exports the stored batch")
    }

    /// A completed read whose files a retry can still publish offers no cleanup
    /// confirmation, because a retry publishes from the library and removes nothing.
    ///
    /// The button is driven by this property, so offering it here would offer a
    /// control that does nothing while the intent line directly above says the retry
    /// removes nothing from the pen.
    func testARetryableCompletionAsksForNoCleanupConfirmation() async throws {
        let library = try makeLibrary(
            publisher: StubPenExportPublisher(failures: [.svg: "the disk is full"])
        )
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertTrue(controller.canRetryExport)
        XCTAssertTrue(controller.isCleanupIntended, "cleanup is still the intended state")
        XCTAssertFalse(
            controller.needsCleanupConfirmation,
            "a retry removes nothing, so it needs no confirmation"
        )
        XCTAssertFalse(controller.isCleanupConfirmedForThisSync)
        XCTAssertTrue(
            controller.canChooseCleanup,
            "the retention choice stays offered for an ordinary read, whose retry honours it"
        )

        // Confirming is refused, which is why the button must not be offered: the
        // two agree that this completion has no cleanup to authorize.
        controller.confirmCleanupForThisSync()
        XCTAssertFalse(controller.isCleanupConfirmedForThisSync)
        XCTAssertFalse(controller.needsCleanupConfirmation)

        // The retry still publishes, and it changes nothing about the pen's copy.
        controller.retryExport()
        try await waitForAttemptToSettle(controller)

        XCTAssertTrue(try XCTUnwrap(controller.outcome).exportSucceeded)

        // The retry published, so this completion is no longer retryable and the
        // confirmation is about the next read again, which needs one.
        XCTAssertFalse(controller.canRetryExport)
        XCTAssertTrue(controller.needsCleanupConfirmation)
    }

    func testRetryIsUnavailableForAReadThatSavedNothing() async throws {
        let library = try makeLibrary(
            publisher: StubPenExportPublisher(failures: [.svg: "the disk is full"])
        )
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: []))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertFalse(controller.canRetryExport, "there is no stored batch to publish")
    }

    func testRetryIsNotOfferedAfterALaterFailedAttempt() async throws {
        let library = try makeLibrary(
            publisher: StubPenExportPublisher(failures: [.svg: "the disk is full"])
        )
        defer { library.remove() }
        let counter = RunnerCounter()
        let read = TestRead.result(strokes: [TestRead.stroke()])
        let penName = self.penName
        let controller = PenSyncController(
            runners: PenSyncRunnerFactory { _ in
                counter.increment()
                return StubPenSyncRunner(
                    stages: [.scanning],
                    outcome: counter.value == 1
                        ? .success(read)
                        : .failure(PenBluetoothError.noMatchingPenFound(advertisedName: penName))
                )
            },
            library: library.importer,
            destination: library.destination
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)
        XCTAssertTrue(controller.canRetryExport)

        // A later failed attempt must not leave a Retry action behind that would
        // republish the older read and present it as the current result.
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertNil(controller.outcome)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.canRetryExport)
    }

    func testEmptyReadStoresNothingAndWritesNoFile() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [], noteCount: 0))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(outcome.isEmpty)
        XCTAssertNil(outcome.save)
        XCTAssertNil(outcome.export)
        XCTAssertTrue(outcome.notice.contains("no strokes"))
        XCTAssertEqual(try library.exportedFiles(), [])
    }

    func testReadWithoutAnExportFolderIsSavedWithoutFiles() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: NoExportDestination(),
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(outcome.isSaved)
        XCTAssertNil(outcome.export)
        XCTAssertFalse(outcome.requestedExport)
        XCTAssertFalse(outcome.exportFailed)
        XCTAssertFalse(outcome.canRetryExport)
        XCTAssertTrue(outcome.notice.contains("No export folder has been chosen"))
        XCTAssertEqual(try library.exportedFiles(), [])
    }

    func testStorageFailureIsPresentedAsAFailureAndLeavesTheLibraryEmpty() async throws {
        let library = try makeLibrary(faultInjection: { _ in throw InjectedStorageFailure.stopped })
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertNil(controller.outcome, "a read that was not stored is not a completed save")
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.phase.isTerminal, true)

        // The store rolled its transaction back, so an interrupted import leaves
        // nothing half-written.
        let pages = try await library.library.pages()
        XCTAssertEqual(pages, [])
    }

    // MARK: - Labels

    func testReadActionsAreLabelledAsReadingSavingAndRetrying() {
        XCTAssertEqual(PenSyncController.readActionTitle, "Read and Save Pen Data")
        XCTAssertFalse(PenSyncController.readActionTitle.localizedCaseInsensitiveContains("export"))
        XCTAssertEqual(PenSyncController.retryExportActionTitle, "Retry Export")
    }

    // MARK: - Failure and retry

    func testFailedAttemptShowsTheErrorAndRetryStartsANewScan() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let counter = RunnerCounter()
        let penName = self.penName
        let controller = PenSyncController(
            runners: PenSyncRunnerFactory { _ in
                counter.increment()
                let attempt = counter.value
                return StubPenSyncRunner(
                    stages: [.scanning, .connecting],
                    outcome: attempt == 1
                        ? .failure(PenBluetoothError.noMatchingPenFound(advertisedName: penName))
                        : .success(TestRead.twelveStrokeResult())
                )
            },
            library: library.importer,
            destination: library.destination
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertEqual(
            controller.errorMessage,
            PenBluetoothError.noMatchingPenFound(advertisedName: penName).message
        )
        XCTAssertNil(controller.errorDiagnostic)
        XCTAssertNil(controller.outcome)

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertEqual(counter.value, 2, "retry must build a fresh runner, and so a fresh scan")
        XCTAssertEqual(controller.outcome?.summary.strokeCount, 12)
        XCTAssertNil(controller.errorMessage)
    }

    func testPartialTransferIsPresentedAsAFailureWithDiagnostic() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            stages: [.scanning, .syncing],
            outcome: .failure(PenSessionError.incompleteTransfer(assembledPacketCount: 3))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertNil(controller.outcome, "partial data must never be presented as a completed sync")
        XCTAssertEqual(
            controller.errorMessage,
            PenSessionError.incompleteTransfer(assembledPacketCount: 3).message
        )
        XCTAssertEqual(controller.errorDiagnostic, "3 packets arrived before the pen stopped sending.")
    }

    func testReadIsIgnoredWhileAnAttemptIsRunning() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let counter = RunnerCounter()
        let controller = PenSyncController(
            runners: PenSyncRunnerFactory { _ in
                counter.increment()
                return StubPenSyncRunner(stages: [.scanning], outcome: .waitsForCancellation)
            },
            library: library.importer,
            destination: library.destination
        )

        controller.readPenData()
        try await waitUntil(controller, is: .scanning)
        controller.readPenData()

        XCTAssertEqual(counter.value, 1)
        controller.cancel()
    }

    // MARK: - Cancellation

    func testCancelReturnsToIdleWithoutReportingCompletion() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            stages: [.scanning, .connecting, .syncing],
            outcome: .waitsForCancellation
        )

        controller.readPenData()
        try await waitUntil(controller, is: .syncing)

        controller.cancel()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.outcome)

        // A late callback from the cancelled attempt must not overwrite idle.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.outcome)
    }

    // MARK: - Several matching pens

    func testSeveralMatchingPensAskForAChoiceAndThenConnectExplicitly() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let first = PenPeripheral(id: UUID(), name: penName)
        let second = PenPeripheral(id: UUID(), name: penName)
        let counter = RunnerCounter()
        let selections = SelectionRecorder()
        let read = TestRead.twelveStrokeResult()
        let penName = self.penName
        let controller = PenSyncController(
            runners: PenSyncRunnerFactory { selection in
                counter.increment()
                selections.record(selection)
                if counter.value == 1 {
                    return StubPenSyncRunner(
                        stages: [.scanning],
                        outcome: .failure(
                            PenBluetoothError.multiplePensFound(
                                advertisedName: penName,
                                candidates: [first, second]
                            )
                        )
                    )
                }
                return StubPenSyncRunner(stages: [.scanning, .syncing], outcome: .success(read))
            },
            library: library.importer,
            destination: library.destination
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertTrue(controller.isAwaitingChoice)
        XCTAssertEqual(controller.penCandidates, [first, second])
        XCTAssertNil(controller.errorMessage, "a choice is a question, not a failure")

        // A plain read while the choice is pending must not start a second scan.
        controller.readPenData()
        XCTAssertEqual(counter.value, 1)

        controller.choosePen(second)
        try await waitForAttemptToSettle(controller)

        XCTAssertEqual(selections.values, [.automatic, .explicit(second)])
        XCTAssertEqual(controller.outcome?.summary.strokeCount, 12)
        XCTAssertFalse(controller.isAwaitingChoice)
    }

    func testCancellingWhileAChoiceIsPendingDoesNotKeepTheChoice() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let first = PenPeripheral(id: UUID(), name: penName)
        let second = PenPeripheral(id: UUID(), name: penName)
        let penName = self.penName
        let controller = PenSyncController(
            runners: PenSyncRunnerFactory { _ in
                StubPenSyncRunner(
                    stages: [.scanning],
                    outcome: .failure(
                        PenBluetoothError.multiplePensFound(
                            advertisedName: penName,
                            candidates: [first, second]
                        )
                    )
                )
            },
            library: library.importer,
            destination: library.destination
        )

        controller.retainPenDataForThisSync()
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        // Asking which pen to use is not a read, so the choice is still the one on
        // screen and the next read is expected to use it.
        XCTAssertTrue(controller.isAwaitingChoice)
        XCTAssertEqual(controller.cleanupIntent, .keepOnPen)

        // Cancelling the question ends the sync the choice was made for, so the
        // choice is not inherited by a later read.
        controller.cancel()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.cleanupIntent, .deleteAfterAcknowledge)
    }

    // MARK: - Cleanup and retention

    func testCleanupIsTheDefaultIntentBeforeTransferAndRetentionIsOffered() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        // Before any transfer, cleanup is what the sync intends, the route is
        // available, and retention is the offered alternative. The confirmation is
        // still outstanding, so the line says what would make the deleting route
        // usable rather than claiming it is armed.
        XCTAssertEqual(controller.cleanupIntent, .deleteAfterAcknowledge)
        XCTAssertTrue(controller.isCleanupIntended)
        XCTAssertTrue(controller.canChooseCleanup)
        XCTAssertTrue(controller.isCleanupAvailable)
        XCTAssertNil(controller.cleanupUnavailableReason)
        XCTAssertTrue(controller.needsCleanupConfirmation)
        XCTAssertEqual(
            controller.cleanupIntentLine,
            "The next read can remove acknowledged packets once you confirm cleanup for it."
        )
        XCTAssertEqual(
            PenSyncController.cleanupIntentStatement,
            "If you confirm cleanup for this read, each packet saved to the local library is removed"
                + " from the pen when the read acknowledges it. The files requested for this read are"
                + " exported afterwards; if that export fails, retry it from the local library."
        )
        XCTAssertEqual(
            PenSyncController.confirmCleanupTitle,
            "Remove Acknowledged Packets for This Read"
        )
        XCTAssertEqual(
            PenSyncController.retainPenDataTitle,
            "Keep Strokes on the Pen for This Read"
        )

        controller.retainPenDataForThisSync()
        XCTAssertEqual(controller.cleanupIntent, .keepOnPen)
        XCTAssertFalse(controller.isCleanupIntended)
        XCTAssertFalse(controller.needsCleanupConfirmation, "retention needs no confirmation")
        XCTAssertEqual(controller.cleanupIntentLine, "The next read keeps the pen's strokes.")

        controller.intendCleanupForThisSync()
        XCTAssertEqual(controller.cleanupIntent, .deleteAfterAcknowledge)
        XCTAssertTrue(controller.needsCleanupConfirmation, "cleanup needs its confirmation again")
    }

    func testRetentionAppliesToOnlyOneSyncAndJournalsNothing() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        controller.retainPenDataForThisSync()
        XCTAssertEqual(controller.cleanupIntent, .keepOnPen, "the choice applies to this sync")
        XCTAssertFalse(controller.isCleanupIntended)
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertEqual(controller.outcome?.cleanup, .retainedByChoice)
        XCTAssertFalse(controller.outcome?.reclaimedPenCopy ?? true)
        let outstanding = try await library.library.outstandingScopes()
        XCTAssertEqual(outstanding, [], "retention must journal no cleanup request")

        // The choice was consumed by that read, so the default is presented again
        // before the next one starts.
        XCTAssertEqual(controller.cleanupIntent, .deleteAfterAcknowledge)
        XCTAssertTrue(controller.isCleanupIntended)

        controller.readPenData()
        try await waitForAttemptToSettle(controller)
        XCTAssertNotEqual(controller.outcome?.cleanup, .retainedByChoice)
    }

    func testARetentionChoiceAtAFinishedReadAppliesToTheNextRead() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)
        XCTAssertFalse(controller.canRetryExport, "the read's files all published")

        // Nothing is left to finish, so the choice made here is the next read's, and
        // the shell says so instead of offering it in the retry's name.
        XCTAssertTrue(controller.canChooseCleanup)
        controller.retainPenDataForThisSync()
        XCTAssertEqual(controller.cleanupIntent, .keepOnPen)
        XCTAssertFalse(controller.isCleanupIntended)

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        // The next read used the choice, and consuming it restored the default.
        XCTAssertEqual(controller.outcome?.cleanup, .retainedByChoice)
        XCTAssertEqual(controller.cleanupIntent, .deleteAfterAcknowledge)
    }

    func testACleanupChoiceAtAFailedReadAppliesToTheNextRead() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let counter = RunnerCounter()
        let penName = self.penName
        let read = TestRead.result(strokes: [TestRead.stroke()])
        let controller = PenSyncController(
            runners: PenSyncRunnerFactory { _ in
                counter.increment()
                return StubPenSyncRunner(
                    stages: [.scanning],
                    outcome: counter.value == 1
                        ? .failure(PenBluetoothError.noMatchingPenFound(advertisedName: penName))
                        : .success(read)
                )
            },
            library: library.importer,
            destination: library.destination
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(controller.canChooseCleanup, "a failed read has nothing left to finish")

        // The choice is the next read's, and the next read honours it rather than
        // discarding it.
        controller.retainPenDataForThisSync()
        XCTAssertEqual(controller.cleanupIntent, .keepOnPen)

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertEqual(controller.outcome?.cleanup, .retainedByChoice)
    }

    func testRetentionChosenBeforeAFailedExportIsHonouredByTheRetry() async throws {
        let library = try makeLibrary(
            publisher: StubPenExportPublisher(failures: [.svg: "the disk is full"])
        )
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        // The read runs with the retention the user chose, and reports it.
        controller.retainPenDataForThisSync()
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        let read = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(read.exportFailed)
        XCTAssertEqual(read.cleanup, .retainedByChoice)

        // The read's own intent is still the one the shell shows, so the retry that
        // finishes it uses retention rather than the policy default.
        XCTAssertEqual(controller.cleanupIntent, .keepOnPen)

        controller.retryExport()
        try await waitForAttemptToSettle(controller)

        let retried = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(retried.exportSucceeded, "the retry must publish the stored read")
        XCTAssertEqual(retried.cleanup, .retainedByChoice)
        let outstanding = try await library.library.outstandingScopes()
        XCTAssertEqual(outstanding, [], "a retention choice must journal no cleanup request")
    }

    func testRetentionChosenAtTheEndOfAReadIsHonouredByTheRetry() async throws {
        let library = try makeLibrary(
            publisher: StubPenExportPublisher(failures: [.svg: "the disk is full"])
        )
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)
        XCTAssertTrue(controller.canRetryExport)

        // The read ran with the default intent, which the closed gate skipped.
        guard case .skipped = try XCTUnwrap(controller.outcome?.cleanup) else {
            return XCTFail("expected the read's cleanup to be skipped by the gate")
        }

        // A retention choice made at the end of the read applies to the retry that
        // finishes it, so the intent the shell shows is the intent that is used, and
        // the line names the retry rather than the next read.
        controller.retainPenDataForThisSync()
        XCTAssertEqual(controller.cleanupIntent, .keepOnPen)
        XCTAssertEqual(
            controller.cleanupIntentLine,
            "Retry Export publishes files from the library and removes nothing from the pen."
        )

        controller.retryExport()
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(outcome.exportSucceeded, "the retry must publish the stored read")
        XCTAssertEqual(outcome.cleanup, .retainedByChoice)
        let outstanding = try await library.library.outstandingScopes()
        XCTAssertEqual(outstanding, [], "a retention choice must journal no cleanup request")
    }

    func testARetryThatFailsAgainKeepsTheRetentionTheUserChose() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let failed = PenExportReport(artifacts: [
            PenExportArtifact(
                format: .svg,
                path: "/tmp/ncode-s3-o27-b700-p1.svg",
                byteCount: 1,
                status: .failed(reason: "the disk is full")
            )
        ])
        let coordinator = StubImportCoordinator(
            outcome: .saved(
                PenLibrarySave(
                    batchID: UUID(),
                    pages: [TestRead.page],
                    insertion: PenStrokeInsertion(addedStrokeCount: 1, duplicateStrokeCount: 0),
                    strokeCount: 1,
                    dotCount: 1
                ),
                export: failed
            ),
            retryReport: failed
        )
        await coordinator.saving.open()
        await coordinator.exporting.open()
        let controller = makeController(
            library: coordinator,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)
        XCTAssertTrue(controller.canRetryExport)

        // The read asked for cleanup and the closed gate skipped it.
        guard case .skipped = try XCTUnwrap(controller.outcome?.cleanup) else {
            return XCTFail("expected the read's cleanup to be skipped by the gate")
        }

        // The user chooses retention, and the retry fails as well: the choice still
        // stands, because nothing was published and no deletion was requested.
        controller.retainPenDataForThisSync()
        controller.retryExport()
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertFalse(outcome.exportSucceeded)
        XCTAssertEqual(outcome.cleanup, .retainedByChoice)
        let requested = await coordinator.requestedCleanupCount()
        XCTAssertEqual(requested, 1, "the failed retry must add no cleanup request")
    }

    func testCancellingARetryRequestsNoCleanup() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let coordinator = StubImportCoordinator(
            outcome: .saved(
                PenLibrarySave(
                    batchID: UUID(),
                    pages: [TestRead.page],
                    insertion: PenStrokeInsertion(addedStrokeCount: 1, duplicateStrokeCount: 0),
                    strokeCount: 1,
                    dotCount: 1
                ),
                export: PenExportReport(artifacts: [
                    PenExportArtifact(
                        format: .svg,
                        path: "/tmp/ncode-s3-o27-b700-p1.svg",
                        byteCount: 1,
                        status: .failed(reason: "the disk is full")
                    )
                ])
            ),
            // The publication is held in flight until the test releases it.
            retry: Gate()
        )
        await coordinator.saving.open()
        await coordinator.exporting.open()
        let controller = makeController(
            library: coordinator,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)
        XCTAssertTrue(controller.canRetryExport)

        // The read itself asked for cleanup once.
        let afterRead = await coordinator.requestedCleanupCount()
        XCTAssertEqual(afterRead, 1, "the read requests cleanup once")

        controller.retryExport()
        try await waitUntil(controller, is: .exporting)

        // The user stops the sync while its publication is still in flight.
        controller.cancel()
        XCTAssertEqual(controller.phase, .idle)

        // The publication finishes anyway, so the cancelled retry has to stop before
        // it asks for cleanup: nothing more may reach the pen for a sync the user
        // ended.
        await coordinator.retry.open()
        try await assertNoFurtherCleanupRequest(coordinator, after: afterRead)
    }

    func testRetentionSurvivesAPenChoiceAndReachesTheChosenRead() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let first = PenPeripheral(id: UUID(), name: penName)
        let second = PenPeripheral(id: UUID(), name: penName)
        let counter = RunnerCounter()
        let penName = self.penName
        let read = TestRead.result(strokes: [TestRead.stroke()])
        let controller = PenSyncController(
            runners: PenSyncRunnerFactory { _ in
                counter.increment()
                if counter.value == 1 {
                    return StubPenSyncRunner(
                        stages: [.scanning],
                        outcome: .failure(
                            PenBluetoothError.multiplePensFound(
                                advertisedName: penName,
                                candidates: [first, second]
                            )
                        )
                    )
                }
                return StubPenSyncRunner(stages: [.scanning, .syncing], outcome: .success(read))
            },
            library: library.importer,
            destination: library.destination
        )

        // The choice is made before the read, and asking which pen to use is not a
        // sync: the intent must survive the question.
        controller.retainPenDataForThisSync()
        controller.readPenData()
        try await waitForAttemptToSettle(controller)
        XCTAssertTrue(controller.isAwaitingChoice)
        XCTAssertEqual(controller.cleanupIntent, .keepOnPen, "a pen choice must not discard the intent")

        controller.choosePen(second)
        try await waitForAttemptToSettle(controller)

        XCTAssertEqual(controller.outcome?.cleanup, .retainedByChoice)
    }

    func testTheCleanupConfirmationSurvivesAPenChoiceAndReachesTheChosenRead() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let first = PenPeripheral(id: UUID(), name: penName)
        let second = PenPeripheral(id: UUID(), name: penName)
        let counter = RunnerCounter()
        let intents = DeletingReadRecorder()
        let penName = self.penName
        let read = TestRead.deletingResult(
            strokes: [TestRead.stroke()],
            packetCount: 1,
            isComplete: true
        )
        // The controller publishes a deleting read's stored rows rather than
        // importing them, so the coordinator only has to answer the publication.
        let coordinator = StubImportCoordinator(
            outcome: .saved(TestRead.save(), export: nil),
            publishReport: PenExportReport(artifacts: [])
        )
        let controller = PenSyncController(
            runners: PenSyncRunnerFactory { _ in
                counter.increment()
                if counter.value == 1 {
                    return StubPenSyncRunner(
                        stages: [.scanning],
                        outcome: .failure(
                            PenBluetoothError.multiplePensFound(
                                advertisedName: penName,
                                candidates: [first, second]
                            )
                        ),
                        intents: intents
                    )
                }
                return StubPenSyncRunner(stages: [.scanning, .syncing], outcome: .success(read), intents: intents)
            },
            library: coordinator,
            destination: library.destination,
            deletingReadStorage: .stub
        )

        // The user confirms cleanup, and then the pen has to be chosen. Asking which
        // pen to use is not a read, so the confirmation the user gave for this sync
        // must survive the question: losing it would run the read non-destructively
        // and keep a pen copy the user asked to remove.
        controller.confirmCleanupForThisSync()
        XCTAssertFalse(controller.needsCleanupConfirmation)
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertTrue(controller.isAwaitingChoice)
        XCTAssertTrue(
            controller.isCleanupConfirmedForThisSync,
            "a pen choice must not discard the confirmation"
        )
        XCTAssertFalse(controller.needsCleanupConfirmation)

        controller.choosePen(second)
        try await waitForAttemptToSettle(controller)

        XCTAssertEqual(intents.values.count, 2)
        XCTAssertNotNil(intents.values[0], "the first attempt was confirmed and asked for deletion")
        XCTAssertNotNil(
            intents.values[1],
            "the read the user chose must still be the confirmed deleting read"
        )
        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(outcome.isDeletingRead)
        XCTAssertEqual(
            outcome.cleanup,
            .acknowledgedPrefix(
                packetCount: 1,
                isComplete: true,
                removalUncertain: false,
                reachedEndPacket: true
            )
        )
    }

    func testTheCleanupIntentCannotBeChangedWhileAnAttemptIsRunning() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let coordinator = StubImportCoordinator(
            outcome: .saved(
                PenLibrarySave(
                    batchID: UUID(),
                    pages: [TestRead.page],
                    insertion: PenStrokeInsertion(addedStrokeCount: 1, duplicateStrokeCount: 0),
                    strokeCount: 1,
                    dotCount: 1
                ),
                export: nil
            )
        )
        let controller = makeController(
            library: coordinator,
            destination: library.destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        // The stub holds its steps open, so the read stays in flight while the
        // intent is tapped.
        await coordinator.exporting.open()
        controller.readPenData()
        try await waitUntil(controller, is: .saving)

        // A tap while the read runs cannot reach that read, which already captured
        // its intent, so it is ignored rather than applied to the next sync. The
        // read started unconfirmed, and the line says so rather than implying the
        // deleting route is armed.
        XCTAssertTrue(controller.isCleanupIntended)
        XCTAssertFalse(controller.canChooseCleanup, "a running read withholds the choice")
        XCTAssertEqual(
            controller.cleanupIntentLine,
            "Keeping the pen's strokes for this read; cleanup was not confirmed.",
            "a running read's line names the read it already captured"
        )
        controller.retainPenDataForThisSync()
        XCTAssertTrue(controller.isCleanupIntended, "a busy attempt must not accept a new intent")

        await coordinator.saving.open()
        try await waitForAttemptToSettle(controller)

        // The read used the intent it started with.
        guard case .skipped = try XCTUnwrap(controller.outcome?.cleanup) else {
            return XCTFail("expected the read to use its captured intent")
        }

        // A settled attempt offers the choice again.
        XCTAssertTrue(controller.canChooseCleanup)
        XCTAssertTrue(controller.isCleanupIntended)
    }

    func testCleanupAvailabilityNamesTheTransferGateWhileTheCommandGateStaysClosed() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let controller = makeController(
            library: library.importer,
            destination: library.destination,
            deletingReadStorage: .unavailable,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        // The deleting route is closed because no durable packet storage is
        // available, and the reason names that transfer-specific blocker rather
        // than the separate `0x25` command's scope.
        XCTAssertFalse(controller.isCleanupAvailable)
        let reason = try XCTUnwrap(controller.cleanupUnavailableReason)
        XCTAssertTrue(reason.contains("durable packet storage"), reason)
        XCTAssertFalse(reason.contains("0x25"), reason)
        XCTAssertEqual(
            controller.cleanupIntentLine,
            "The next read keeps the pen's strokes because cleanup is unavailable."
        )

        // The read still saves, the pen keeps its copy, and the shell says why.
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(outcome.isSaved, "a closed route must not stop the read being stored")
        XCTAssertFalse(outcome.reclaimedPenCopy)
        guard case .skipped(let skipReason) = outcome.cleanup else {
            return XCTFail("expected a skipped cleanup, got \(outcome.cleanup)")
        }
        // The ordinary read's cleanup is the separate command, so its skip reason
        // is the command gate's: the two routes are reported independently.
        XCTAssertTrue(skipReason.contains("deletion evidence gate"), skipReason)
        XCTAssertTrue(outcome.cleanupNotice.contains("The pen kept its strokes"), outcome.cleanupNotice)
    }

    func testReportsEveryCleanupOutcome() async throws {
        let save = PenLibrarySave(
            batchID: UUID(),
            pages: [TestRead.page],
            insertion: PenStrokeInsertion(addedStrokeCount: 1, duplicateStrokeCount: 0),
            strokeCount: 1,
            dotCount: 1
        )
        let report = PenExportReport(
            artifacts: [
                PenExportArtifact(
                    format: .json,
                    path: "/tmp/ncode-s3-o27-b700-p1.json",
                    byteCount: 12,
                    status: .published
                )
            ]
        )
        let destination = FixedExportDestination(directory: FileManager.default.temporaryDirectory.path)

        let crafted: [(PenCleanupOutcome, String, Bool)] = [
            (.reclaimed(pageCount: 2), "Reclaimed 2 pages", true),
            (.skipped(reason: "the deletion evidence gate is closed"), "gate is closed", false),
            (.outstanding(reason: "no acknowledgement arrived"), "outstanding", false),
        ]

        for (cleanup, phrase, isReclaimed) in crafted {
            let coordinator = StubImportCoordinator(
                outcome: .saved(save, export: report),
                cleanup: cleanup
            )
            // The stub holds its steps open for a test that watches the phases, so
            // this test releases them before starting the read.
            await coordinator.saving.open()
            await coordinator.exporting.open()
            let controller = makeController(
                library: coordinator,
                destination: destination,
                outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
            )

            controller.readPenData()
            try await waitForAttemptToSettle(controller)

            let outcome = try XCTUnwrap(controller.outcome)
            XCTAssertEqual(outcome.cleanup, cleanup)
            XCTAssertEqual(outcome.reclaimedPenCopy, isReclaimed)
            XCTAssertTrue(outcome.cleanupNotice.contains(phrase), outcome.cleanupNotice)
        }

        // Retention is the fourth outcome, and the stub reports it for the mode
        // the controller sends.
        let coordinator = StubImportCoordinator(outcome: .saved(save, export: report))
        await coordinator.saving.open()
        await coordinator.exporting.open()
        let controller = makeController(
            library: coordinator,
            destination: destination,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )
        controller.retainPenDataForThisSync()
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertEqual(outcome.cleanup, .retainedByChoice)
        XCTAssertFalse(outcome.reclaimedPenCopy)
        XCTAssertTrue(outcome.cleanupNotice.contains("kept on the pen"), outcome.cleanupNotice)
    }

    // MARK: - Deleting reads

    func testNoExportRequestNeverRequestsADeletingReadAndSaysWhy() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let intents = DeletingReadRecorder()
        let controller = makeController(
            library: library.importer,
            destination: NoExportDestination(),
            intents: intents,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )

        // No export was requested, so there is nothing to fall back on if the
        // pen's copy went away, and the reason names exactly that.
        XCTAssertFalse(controller.isCleanupAvailable)
        XCTAssertEqual(
            controller.cleanupUnavailableReason,
            PenDeletingReadRefusal.noExportRequested.reason
        )

        // Even an explicit confirmation cannot open the route without an export.
        controller.confirmCleanupForThisSync()
        XCTAssertFalse(controller.isCleanupConfirmedForThisSync)
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertEqual(intents.values.count, 1)
        XCTAssertNil(intents.values[0], "a no-export sync must request an ordinary read")
        XCTAssertFalse(try XCTUnwrap(controller.outcome).isDeletingRead)
    }

    func testConfirmationAuthorizesOneDeletingReadAndTheNextSyncAsksAgain() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let intents = DeletingReadRecorder()
        let read = TestRead.deletingResult(strokes: [TestRead.stroke()], packetCount: 1, isComplete: true)
        let controller = makeController(
            library: StubImportCoordinator(outcome: .saved(TestRead.save(), export: nil)),
            destination: library.destination,
            intents: intents,
            outcome: .success(read)
        )

        XCTAssertTrue(controller.needsCleanupConfirmation)
        controller.confirmCleanupForThisSync()
        XCTAssertTrue(controller.isCleanupConfirmedForThisSync)
        XCTAssertFalse(controller.needsCleanupConfirmation)

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        // The confirmation is what authorized the deleting request, and it travelled
        // with the read as a confirmation made for this sync.
        let first = try XCTUnwrap(intents.values.first ?? nil)
        XCTAssertTrue(first.confirmedForThisSync)
        XCTAssertTrue(first.requestedExport)
        XCTAssertTrue(first.durablePacketStorageAvailable)
        XCTAssertTrue(try XCTUnwrap(controller.outcome).isDeletingRead)

        // Consent is for one sync: the next read starts unconfirmed and asks again.
        XCTAssertTrue(controller.needsCleanupConfirmation)
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertEqual(intents.values.count, 2)
        XCTAssertNil(intents.values[1], "a later sync must not inherit the confirmation")
    }

    /// The headless acceptance run applies its cleanup choice through the same calls
    /// the menu makes, so a run only deletes when it confirmed cleanup for its sync.
    ///
    /// This is the checklist's vehicle for the physical deleting-read acceptance, so
    /// a run that silently took the non-destructive path would produce a transcript
    /// that looks like a passing deleting read.
    func testAHeadlessRunOnlyDeletesWhenItConfirmedCleanup() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let read = TestRead.deletingResult(strokes: [TestRead.stroke()], packetCount: 1, isComplete: true)

        // Intent only: the run must take the ordinary non-destructive read, which
        // goes through the saving and exporting steps the gates hold open.
        let unconfirmed = DeletingReadRecorder()
        let unconfirmedLibrary = StubImportCoordinator(outcome: .saved(TestRead.save(), export: nil))
        await unconfirmedLibrary.saving.open()
        await unconfirmedLibrary.exporting.open()
        let unconfirmedController = makeController(
            library: unconfirmedLibrary,
            destination: library.destination,
            intents: unconfirmed,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )
        let unconfirmedOptions = PenAcceptanceOptions(
            traceURL: URL(fileURLWithPath: "/tmp/a1-run.txt"),
            cleanupMode: .deleteAfterAcknowledge,
            confirmCleanup: false
        )
        unconfirmedOptions.applyCleanupChoice(to: unconfirmedController)

        XCTAssertTrue(unconfirmedController.isCleanupIntended)
        XCTAssertTrue(unconfirmedController.needsCleanupConfirmation)

        unconfirmedController.readPenData()
        try await waitForAttemptToSettle(unconfirmedController)

        XCTAssertEqual(unconfirmed.values.count, 1)
        XCTAssertNil(unconfirmed.values[0], "an unconfirmed run must not ask for a deleting read")
        XCTAssertFalse(try XCTUnwrap(unconfirmedController.outcome).isDeletingRead)

        // Intent and confirmation: the run takes the deleting path, whose
        // publication is the coordinator's own `publish` rather than the saving and
        // exporting steps.
        let confirmed = DeletingReadRecorder()
        let confirmedController = makeController(
            library: StubImportCoordinator(outcome: .saved(TestRead.save(), export: nil)),
            destination: library.destination,
            intents: confirmed,
            outcome: .success(read)
        )
        PenAcceptanceOptions(
            traceURL: URL(fileURLWithPath: "/tmp/a1-run.txt"),
            cleanupMode: .deleteAfterAcknowledge,
            confirmCleanup: true
        ).applyCleanupChoice(to: confirmedController)

        XCTAssertFalse(confirmedController.needsCleanupConfirmation)

        confirmedController.readPenData()
        try await waitForAttemptToSettle(confirmedController)

        let intent = try XCTUnwrap(confirmed.values.first ?? nil)
        XCTAssertTrue(intent.confirmedForThisSync)
        XCTAssertTrue(try XCTUnwrap(confirmedController.outcome).isDeletingRead)

        // A run that asks for retention keeps the pen's copy whatever the flag says,
        // which the parser refuses to combine with a confirmation.
        let retained = DeletingReadRecorder()
        let retainedLibrary = StubImportCoordinator(outcome: .saved(TestRead.save(), export: nil))
        await retainedLibrary.saving.open()
        await retainedLibrary.exporting.open()
        let retainedController = makeController(
            library: retainedLibrary,
            destination: library.destination,
            intents: retained,
            outcome: .success(TestRead.result(strokes: [TestRead.stroke()]))
        )
        PenAcceptanceOptions(
            traceURL: URL(fileURLWithPath: "/tmp/a1-run.txt"),
            cleanupMode: .keepOnPen
        ).applyCleanupChoice(to: retainedController)

        XCTAssertFalse(retainedController.isCleanupIntended)

        retainedController.readPenData()
        try await waitForAttemptToSettle(retainedController)

        XCTAssertEqual(retained.values.count, 1)
        XCTAssertNil(retained.values[0], "a retaining run must not ask for a deleting read")
        XCTAssertFalse(try XCTUnwrap(retainedController.outcome).isDeletingRead)
    }

    func testCompletedDeletingReadReportsTheAcknowledgedPrefix() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let read = TestRead.deletingResult(
            strokes: [TestRead.stroke(), TestRead.stroke(x: 20)],
            packetCount: 2,
            isComplete: true
        )
        let controller = makeController(
            library: StubImportCoordinator(outcome: .saved(TestRead.save(), export: nil)),
            destination: library.destination,
            outcome: .success(read)
        )

        controller.confirmCleanupForThisSync()
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(outcome.isDeletingRead)
        XCTAssertFalse(outcome.isPartialDeletingRead)
        XCTAssertTrue(outcome.isSaved)
        XCTAssertEqual(
            outcome.cleanup,
            .acknowledgedPrefix(
                packetCount: 2,
                isComplete: true,
                removalUncertain: false,
                reachedEndPacket: true
            )
        )
        XCTAssertTrue(outcome.reclaimedPenCopy)
        XCTAssertTrue(outcome.cleanupNotice.contains("2 acknowledged packets"), outcome.cleanupNotice)
        XCTAssertTrue(
            outcome.cleanupNotice.contains("library copy remains available"),
            outcome.cleanupNotice
        )
        XCTAssertTrue(
            outcome.notice.contains("acknowledged packets were removed"),
            outcome.notice
        )
        XCTAssertEqual(
            controller.statusLabel,
            "Complete",
            "a deleting read that reached every end packet is a completed sync"
        )
    }

    func testPartialDeletingReadReportsThePrefixAndOffersFreshReadAndRetry() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let read = TestRead.deletingResult(
            strokes: [TestRead.stroke(), TestRead.stroke(x: 20)],
            packetCount: 1,
            isComplete: false,
            reason: "the pen stopped sending"
        )
        let coordinator = StubImportCoordinator(
            outcome: .saved(TestRead.save(), export: nil),
            retryReport: PenExportReport(artifacts: [
                PenExportArtifact(
                    format: .svg,
                    path: "/tmp/ncode-s3-o27-b700-p1.svg",
                    byteCount: 1,
                    status: .published
                )
            ]),
            publishReport: PenExportReport(artifacts: [
                PenExportArtifact(
                    format: .svg,
                    path: "/tmp/ncode-s3-o27-b700-p1.svg",
                    byteCount: 1,
                    status: .failed(reason: "the disk is full")
                )
            ])
        )
        let controller = makeController(
            library: coordinator,
            destination: library.destination,
            outcome: .success(read)
        )

        controller.confirmCleanupForThisSync()
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        let partial = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(partial.isPartialDeletingRead)
        XCTAssertEqual(
            controller.statusLabel,
            "Partial",
            "a partial deleting read must never read as a completed sync"
        )
        XCTAssertEqual(
            partial.cleanup,
            .acknowledgedPrefix(
                packetCount: 1,
                isComplete: false,
                removalUncertain: false,
                reachedEndPacket: false
            )
        )
        XCTAssertTrue(
            partial.cleanupNotice.contains("the pen may still hold the remainder"),
            partial.cleanupNotice
        )
        XCTAssertTrue(partial.exportFailed, "the requested export did not publish")
        XCTAssertTrue(controller.canRetryExport)

        // A fresh read is offered, because the remainder is still on the pen, but no
        // cleanup choice is: this completed read removed what it stored as it read it,
        // so the retry only republishes the durable copy and a choice could only
        // change a control that removes nothing.
        XCTAssertFalse(controller.canChooseCleanup)
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(
            controller.needsCleanupConfirmation,
            "a retry removes nothing, so it needs no confirmation either"
        )

        // The retry republishes the durable pages and never asks for a separate
        // deletion command, because the deleting transfer already removed what it
        // acknowledged.
        controller.retryExport()
        try await waitForAttemptToSettle(controller)

        let retried = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(retried.exportSucceeded)
        XCTAssertTrue(retried.isPartialDeletingRead, "a retry must not complete the read")
        XCTAssertEqual(
            retried.cleanup,
            .acknowledgedPrefix(
                packetCount: 1,
                isComplete: false,
                removalUncertain: false,
                reachedEndPacket: false
            )
        )
        let requested = await coordinator.requestedCleanupCount()
        XCTAssertEqual(requested, 0, "a deleting batch must never request a separate deletion")
    }

    /// A transfer that reached its last packet whose completion could not be recorded
    /// must not be reported as a short read.
    ///
    /// The two states share `isComplete == false`, so without the transfer's own fact
    /// the shell would tell the user the pen may still hold a remainder when it holds
    /// none, and would hide the storage failure that is the real cause.
    func testAnUnrecordedCompletionIsNotReportedAsAShortRead() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let read = TestRead.deletingResult(
            strokes: [TestRead.stroke(), TestRead.stroke(x: 20)],
            packetCount: 2,
            isComplete: false,
            reachedEndPacket: true,
            reason: "the read's completion could not be recorded: the disk is full"
        )
        let controller = makeController(
            library: StubImportCoordinator(outcome: .saved(TestRead.save(), export: nil)),
            destination: library.destination,
            outcome: .success(read)
        )

        controller.confirmCleanupForThisSync()
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertTrue(outcome.isPartialDeletingRead, "the durable record says not complete")
        XCTAssertEqual(controller.statusLabel, "Partial")

        // The pen's copy is gone, and the reason names the storage failure rather than
        // a transfer that stopped short.
        XCTAssertTrue(
            outcome.cleanupNotice.contains("the pen holds no remainder of it"),
            outcome.cleanupNotice
        )
        XCTAssertFalse(
            outcome.cleanupNotice.contains("the pen may still hold the remainder"),
            outcome.cleanupNotice
        )
        XCTAssertTrue(
            outcome.notice.contains("the read's completion could not be recorded"),
            outcome.notice
        )
        XCTAssertFalse(
            outcome.notice.contains("the pen may still hold the remainder"),
            outcome.notice
        )
    }

    func testUncertainAcknowledgementIsReportedAsUncertain() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let read = TestRead.deletingResult(
            strokes: [TestRead.stroke()],
            packetCount: 1,
            isComplete: false,
            acknowledgementUncertain: true,
            reason: "the acknowledgement could not be sent"
        )
        let controller = makeController(
            library: StubImportCoordinator(outcome: .saved(TestRead.save(), export: nil)),
            destination: library.destination,
            outcome: .success(read)
        )

        controller.confirmCleanupForThisSync()
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertEqual(
            outcome.cleanup,
            .acknowledgedPrefix(
                packetCount: 1,
                isComplete: false,
                removalUncertain: true,
                reachedEndPacket: false
            )
        )
        XCTAssertTrue(
            outcome.cleanupNotice.contains("acknowledgement was not confirmed"),
            outcome.cleanupNotice
        )
        XCTAssertTrue(
            outcome.notice.contains("acknowledgement was not confirmed"),
            outcome.notice
        )
    }

    func testARefusedDeletingRouteIsSavedNonDestructivelyAndReportedAsSkipped() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        // The pen's identity closed the deleting route after the handshake, so the
        // session read non-destructively and named the blocker.
        let refusal = "the deleting-transfer evidence gate is closed for protocol 2.18"
        let read = TestRead.refusedDeletingResult(
            strokes: [TestRead.stroke(), TestRead.stroke(x: 20)],
            refusal: refusal
        )
        let coordinator = StubImportCoordinator(
            outcome: .saved(TestRead.save(), export: nil),
            cleanup: .reclaimed(pageCount: 1)
        )
        // The stub holds its steps open for a test that watches the phases, so this
        // test releases them before starting the read.
        await coordinator.saving.open()
        await coordinator.exporting.open()
        let controller = makeController(
            library: coordinator,
            destination: library.destination,
            outcome: .success(read)
        )

        controller.confirmCleanupForThisSync()
        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        let outcome = try XCTUnwrap(controller.outcome)
        XCTAssertFalse(outcome.isDeletingRead, "the fallback is an ordinary read")
        XCTAssertTrue(outcome.isSaved, "the read still reaches the library")
        XCTAssertFalse(outcome.reclaimedPenCopy)
        // The refusal names why the deleting route closed, not the command gate.
        XCTAssertEqual(outcome.cleanup, .skipped(reason: refusal))
        XCTAssertEqual(
            outcome.cleanupNotice,
            "The pen kept its strokes: \(refusal)",
            "the notice must name the blocker that kept the read non-destructive"
        )

        // No separate deletion command was requested for the fallback: the read was
        // never authorized to remove anything.
        let requested = await coordinator.requestedCleanupCount()
        XCTAssertEqual(requested, 0, "a refused deleting route must not request cleanup")
    }

    func testCancellingADeletingReadLeavesNoCompletedResult() async throws {
        let library = try makeLibrary()
        defer { library.remove() }
        let controller = makeController(
            library: StubImportCoordinator(outcome: .saved(TestRead.save(), export: nil)),
            destination: library.destination,
            outcome: .waitsForCancellation
        )

        controller.confirmCleanupForThisSync()
        controller.readPenData()
        try await waitUntil(controller, is: .syncing)

        controller.cancel()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.outcome, "a cancelled deleting read claims nothing")
        // The cancelled sync consumed its confirmation, so the next one asks again.
        XCTAssertTrue(controller.needsCleanupConfirmation)
    }

    // MARK: - Helpers

    private func makeLibrary(
        publisher: any PenExportPublisher = FilePenExportPublisher(),
        policy: PenCleanupPolicy = PenCleanupPolicy(),
        faultInjection: (@Sendable (Int) throws -> Void)? = nil
    ) throws -> TestLibrary {
        try TestLibrary(publisher: publisher, policy: policy, faultInjection: faultInjection)
    }

    private func makeController(
        library: any PenImportCoordinator,
        destination: any PenExportDestinationProviding,
        stages: [PenSyncStage] = [.scanning, .connecting, .verifying, .syncing],
        cleanupPolicy: PenCleanupPolicy = PenCleanupPolicy(),
        deletingReadStorage: PenDeletingReadStorage = .stub,
        intents: DeletingReadRecorder? = nil,
        outcome: StubPenSyncRunner.Outcome
    ) -> PenSyncController {
        PenSyncController(
            runners: PenSyncRunnerFactory { _ in
                StubPenSyncRunner(stages: stages, outcome: outcome, intents: intents)
            },
            library: library,
            destination: destination,
            cleanupPolicy: cleanupPolicy,
            deletingReadStorage: deletingReadStorage
        )
    }

    /// Waits until the controller reaches a specific phase.
    private func waitUntil(
        _ controller: PenSyncController,
        is phase: PenSyncController.Phase,
        timeout: Duration = .seconds(3)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if controller.phase == phase { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the phase never became \(phase); it is \(controller.phase)")
    }

    /// Waits until the attempt reaches a terminal phase or asks for a choice.
    private func waitForAttemptToSettle(
        _ controller: PenSyncController,
        timeout: Duration = .seconds(3)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if controller.phase.isTerminal || controller.isAwaitingChoice { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the attempt never settled; the phase is \(controller.phase)")
    }

    /// Proves a coordinator receives no further cleanup request within a bounded
    /// window.
    ///
    /// The window is what makes a "nothing more happened" assertion meaningful: the
    /// controller's continuation after a cancelled publication runs promptly, so a
    /// request that was going to be made would appear well inside it.
    private func assertNoFurtherCleanupRequest(
        _ coordinator: StubImportCoordinator,
        after expected: Int,
        window: Duration = .milliseconds(250)
    ) async throws {
        let deadline = ContinuousClock.now + window
        while ContinuousClock.now < deadline {
            let count = await coordinator.requestedCleanupCount()
            XCTAssertEqual(count, expected, "a cancelled retry must not request cleanup")
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
