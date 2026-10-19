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

    // MARK: - Helpers

    private func makeLibrary(
        publisher: any PenExportPublisher = FilePenExportPublisher(),
        faultInjection: (@Sendable (Int) throws -> Void)? = nil
    ) throws -> TestLibrary {
        try TestLibrary(publisher: publisher, faultInjection: faultInjection)
    }

    private func makeController(
        library: any PenImportCoordinator,
        destination: any PenExportDestinationProviding,
        stages: [PenSyncStage] = [.scanning, .connecting, .verifying, .syncing],
        outcome: StubPenSyncRunner.Outcome
    ) -> PenSyncController {
        PenSyncController(
            runners: PenSyncRunnerFactory { _ in
                StubPenSyncRunner(stages: stages, outcome: outcome)
            },
            library: library,
            destination: destination
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
}
