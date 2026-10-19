import Foundation
import NeoBridgeMacCore
import NeoProtocol
import XCTest

/// Tests for the shell's state machine, driven by stubbed runners.
///
/// Every test uses ``StubPenSyncRunner``, so the shell's presentation is checked
/// without a radio and without a pen.
@MainActor
final class PenSyncControllerTests: XCTestCase {
    private let penName = CoreBluetoothPenTransport.advertisedName

    // MARK: - Progress and results

    func testPresentsEachInProgressStage() async throws {
        for stage in [PenSyncStage.scanning, .connecting, .verifying, .syncing] {
            let controller = makeController(stages: [stage], outcome: .waitsForCancellation)

            controller.readPenData()
            try await waitUntil(controller, is: PenSyncController.Phase(stage))

            XCTAssertTrue(controller.isBusy)
            XCTAssertNil(controller.result)

            controller.cancel()
            XCTAssertEqual(controller.phase, .idle)
        }
    }

    func testShowsTheFinalCountsAfterACompleteRead() async throws {
        let summary = Self.summary()
        let controller = makeController(
            stages: [.scanning, .connecting, .verifying, .syncing],
            outcome: .success(summary)
        )

        controller.readPenData()
        XCTAssertEqual(controller.phase, .scanning, "progress must be visible before the first await")
        try await waitForAttemptToSettle(controller)

        XCTAssertEqual(controller.phase, .complete(summary))
        XCTAssertEqual(controller.result?.strokeCount, 12)
        XCTAssertEqual(controller.result?.dotCount, 240)
        XCTAssertEqual(controller.result?.distinctPageCount, 3)
        XCTAssertEqual(controller.result?.notes.map(\.label), ["Note 700 · section 3 · owner 27"])
        XCTAssertFalse(controller.isBusy)
    }

    func testCompleteReadIsLabelledUnsaved() async throws {
        let controller = makeController(stages: [.scanning], outcome: .success(Self.summary()))

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertTrue(PenSyncController.notSavedNotice.contains("in memory"))
        XCTAssertTrue(PenSyncController.notSavedNotice.contains("written to disk"))
        XCTAssertTrue(PenSyncController.notSavedNotice.contains("exported"))
    }

    func testLabelsTheRetrievalActionAsReadingPenData() {
        XCTAssertEqual(PenSyncController.readActionTitle, "Read Pen Data")
        XCTAssertFalse(PenSyncController.readActionTitle.localizedCaseInsensitiveContains("import"))
        XCTAssertFalse(PenSyncController.readActionTitle.localizedCaseInsensitiveContains("export"))
    }

    // MARK: - Failure and retry

    func testFailedAttemptShowsTheErrorAndRetryStartsANewScan() async throws {
        let counter = RunnerCounter()
        let summary = Self.summary()
        let penName = self.penName
        let controller = PenSyncController(
            runners: PenSyncRunnerFactory { _ in
                counter.increment()
                let attempt = counter.value
                return StubPenSyncRunner(
                    stages: [.scanning, .connecting],
                    outcome: attempt == 1
                        ? .failure(PenBluetoothError.noMatchingPenFound(advertisedName: penName))
                        : .success(summary)
                )
            }
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertEqual(
            controller.errorMessage,
            PenBluetoothError.noMatchingPenFound(advertisedName: penName).message
        )
        XCTAssertNil(controller.errorDiagnostic)
        XCTAssertNil(controller.result)

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertEqual(counter.value, 2, "retry must build a fresh runner, and so a fresh scan")
        XCTAssertEqual(controller.result?.strokeCount, 12)
        XCTAssertNil(controller.errorMessage)
    }

    func testPartialTransferIsPresentedAsAFailureWithDiagnostic() async throws {
        let controller = makeController(
            stages: [.scanning, .syncing],
            outcome: .failure(PenSessionError.incompleteTransfer(assembledPacketCount: 3))
        )

        controller.readPenData()
        try await waitForAttemptToSettle(controller)

        XCTAssertNil(controller.result, "partial data must never be presented as a completed sync")
        XCTAssertEqual(
            controller.errorMessage,
            PenSessionError.incompleteTransfer(assembledPacketCount: 3).message
        )
        XCTAssertEqual(controller.errorDiagnostic, "3 packets arrived before the pen stopped sending.")
    }

    func testReadIsIgnoredWhileAnAttemptIsRunning() async throws {
        let counter = RunnerCounter()
        let controller = PenSyncController(
            runners: PenSyncRunnerFactory { _ in
                counter.increment()
                return StubPenSyncRunner(stages: [.scanning], outcome: .waitsForCancellation)
            }
        )

        controller.readPenData()
        try await waitUntil(controller, is: .scanning)
        controller.readPenData()

        XCTAssertEqual(counter.value, 1)
        controller.cancel()
    }

    // MARK: - Cancellation

    func testCancelReturnsToIdleWithoutReportingCompletion() async throws {
        let controller = makeController(
            stages: [.scanning, .connecting, .syncing],
            outcome: .waitsForCancellation
        )

        controller.readPenData()
        try await waitUntil(controller, is: .syncing)

        controller.cancel()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.result)

        // A late callback from the cancelled attempt must not overwrite idle.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.result)
    }

    // MARK: - Several matching pens

    func testSeveralMatchingPensAskForAChoiceAndThenConnectExplicitly() async throws {
        let first = PenPeripheral(id: UUID(), name: penName)
        let second = PenPeripheral(id: UUID(), name: penName)
        let counter = RunnerCounter()
        let selections = SelectionRecorder()
        let summary = Self.summary()
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
                return StubPenSyncRunner(stages: [.scanning, .syncing], outcome: .success(summary))
            }
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
        XCTAssertEqual(controller.result?.strokeCount, 12)
        XCTAssertFalse(controller.isAwaitingChoice)
    }

    // MARK: - Helpers

    private func makeController(
        stages: [PenSyncStage],
        outcome: StubPenSyncRunner.Outcome
    ) -> PenSyncController {
        PenSyncController(
            runners: PenSyncRunnerFactory { _ in
                StubPenSyncRunner(stages: stages, outcome: outcome)
            }
        )
    }

    private static func summary() -> PenSyncSummary {
        PenSyncSummary(
            strokeCount: 12,
            dotCount: 240,
            distinctPageCount: 3,
            notes: [
                PenSyncNoteSummary(
                    note: PenOfflineNote(section: 3, owner: 27, note: 700),
                    strokeCount: 12,
                    dotCount: 240
                )
            ]
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
