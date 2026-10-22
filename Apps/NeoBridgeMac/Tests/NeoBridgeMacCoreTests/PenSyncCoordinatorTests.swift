import Foundation
import NeoBridgeMacCore
import NeoCore
import NeoProtocol
import XCTest

/// Tests for the automatic sync schedule.
///
/// The schedule is driven by a fake clock and a fake adapter, so "the pen
/// appeared", "an interval elapsed", and "a read is still running" are statements
/// the test makes rather than conditions it waits for. Every read is scripted, so
/// no test needs a radio.
@MainActor
final class PenSyncCoordinatorTests: XCTestCase {
    private let penName = CoreBluetoothPenTransport.advertisedName

    // MARK: - Discovery and interval pacing

    func testLaunchDiscoversThePenAndStartsOneRead() async throws {
        let fixture = makeFixture()
        fixture.coordinator.start()

        try await waitUntil("the first read to start") { fixture.recorder.startCount == 1 }
        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }

        XCTAssertEqual(fixture.recorder.startCount, 1)
        XCTAssertTrue(
            fixture.central.events.contains("observe"),
            "an unpaused launch must start discovery without a click"
        )

        await finish(fixture)
    }

    func testTheObservationStopsBeforeTheReadStartsItsSelectionScan() async throws {
        let fixture = makeFixture(runner: { central in
            HandoffRunner(central: central, read: TestRead.result(strokes: [TestRead.stroke()]))
        })
        fixture.coordinator.start()

        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }

        // The radio runs one scan at a time, so the schedule has to release its
        // observation before the read asks for its own bounded selection scan.
        XCTAssertEqual(
            Array(fixture.central.events.prefix(3)),
            ["observe", "stopObservation", "scan"],
            "the handoff must stop observation before the read scans"
        )

        await finish(fixture)
    }

    func testASecondReadComesAtTheSavedIntervalAndNotBefore() async throws {
        let fixture = makeFixture()
        fixture.coordinator.start()

        try await waitUntil("the first read") { fixture.recorder.startCount == 1 }
        try await waitUntil("it to settle") { fixture.controller.outcome != nil }

        // The pen is still in range, and nothing about a completed read starts
        // another one: the interval is what does.
        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        fixture.clock.advance(by: .seconds(300))
        try await waitUntil("the interval read") { fixture.recorder.startCount == 2 }

        await finish(fixture)
    }

    func testAChangedIntervalPacesTheNextOpportunity() async throws {
        let fixture = makeFixture(interval: .thirtyMinutes)
        fixture.coordinator.start()

        try await waitUntil("the first read") { fixture.recorder.startCount == 1 }
        try await waitUntil("it to settle") { fixture.controller.outcome != nil }

        // The shorter interval the user picks applies to the next opportunity
        // rather than only to the one after it.
        fixture.controller.selectSyncInterval(.oneMinute)
        fixture.clock.advance(by: .seconds(60))

        try await waitUntil("the read at the new interval") { fixture.recorder.startCount == 2 }

        await finish(fixture)
    }

    func testAnAbsentPenIsPacedByTheInterval() async throws {
        let penName = self.penName
        let fixture = makeFixture(
            pen: nil,
            recorder: CoordinatorRunnerRecorder(
                failure: PenBluetoothError.noMatchingPenFound(advertisedName: penName)
            )
        )
        fixture.coordinator.start()

        try await assertNoReads(fixture, after: 0, window: .milliseconds(150))

        // The opportunity still runs with no pen in range, so the read reports
        // "no pen found" in Connection Details instead of the app going quiet.
        fixture.clock.advance(by: .seconds(300))
        try await waitUntil("the interval attempt") { fixture.recorder.startCount == 1 }
        try await waitUntil("its failure to be reported") { fixture.controller.errorMessage != nil }

        try await assertNoReads(fixture, after: 1, window: .milliseconds(150))

        await finish(fixture)
    }

    func testAFailedReadIsPacedByTheInterval() async throws {
        let penName = self.penName
        let fixture = makeFixture(
            recorder: CoordinatorRunnerRecorder(
                failure: PenBluetoothError.noMatchingPenFound(advertisedName: penName)
            )
        )
        fixture.coordinator.start()

        try await waitUntil("the first attempt") { fixture.recorder.startCount == 1 }
        try await waitUntil("its failure to be reported") { fixture.controller.errorMessage != nil }

        // A failure keeps the mode and the interval, and it does not start a rapid
        // retry loop: the next attempt is the next interval.
        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        fixture.clock.advance(by: .seconds(300))
        try await waitUntil("the next attempt") { fixture.recorder.startCount == 2 }

        await finish(fixture)
    }

    // MARK: - One read at a time

    func testNoSecondReadStartsWhileOneIsInFlight() async throws {
        let fixture = makeFixture(recorder: CoordinatorRunnerRecorder(holdsAttempts: true))
        fixture.coordinator.start()

        try await waitUntil("the read to start") { fixture.recorder.startCount == 1 }

        // Several intervals elapse while the read is still running. They coalesce
        // into one next opportunity rather than stacking up behind it.
        fixture.clock.advance(by: .seconds(1800))
        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        fixture.recorder.gate.open()
        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }
        try await waitUntil("one coalesced attempt") { fixture.recorder.startCount == 2 }

        try await assertNoReads(fixture, after: 2, window: .milliseconds(200))

        await finish(fixture)
    }

    // MARK: - Appearances

    func testSilenceLongerThanTheFreshnessWindowIsANewAppearance() async throws {
        let pen = PenPeripheral(id: UUID(), name: penName)
        let fixture = makeFixture(pen: pen)
        fixture.coordinator.start()

        try await waitUntil("the first read") { fixture.recorder.startCount == 1 }
        try await waitUntil("it to settle") { fixture.controller.outcome != nil }
        try await waitUntil("observation to resume") { fixture.central.isObserving }

        // The pen is still in range and the interval has not elapsed, so nothing
        // starts another read.
        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        // It goes quiet for longer than the freshness window and advertises again.
        fixture.clock.advance(by: .seconds(31))
        fixture.central.emit(pen)

        try await waitUntil("a read for the new appearance") { fixture.recorder.startCount == 2 }

        await finish(fixture)
    }

    func testAShortSilenceIsNotANewAppearance() async throws {
        let pen = PenPeripheral(id: UUID(), name: penName)
        let fixture = makeFixture(pen: pen)
        fixture.coordinator.start()

        try await waitUntil("the first read") { fixture.recorder.startCount == 1 }
        try await waitUntil("it to settle") { fixture.controller.outcome != nil }
        try await waitUntil("observation to resume") { fixture.central.isObserving }

        // A gap shorter than the freshness window is a pen that stayed around, so
        // the interval still governs when the next read happens.
        fixture.clock.advance(by: .seconds(20))
        fixture.central.emit(pen)

        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        await finish(fixture)
    }

    func testAReadThatOutlastsTheFreshnessWindowIsNotANewAppearance() async throws {
        let pen = PenPeripheral(id: UUID(), name: penName)
        let fixture = makeFixture(
            pen: pen,
            recorder: CoordinatorRunnerRecorder(holdsAttempts: true)
        )
        fixture.coordinator.start()

        try await waitUntil("the read to start") { fixture.recorder.startCount == 1 }

        // The read outlasts the freshness window. The pen never left, so its next
        // advertisement must not look like one that did.
        fixture.clock.advance(by: .seconds(45))
        fixture.recorder.gate.open()

        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }
        try await waitUntil("observation to resume") { fixture.central.isObserving }

        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        await finish(fixture)
    }

    // MARK: - Paused

    func testPausedStopsDiscoveryAndAResumedModeStartsItAgain() async throws {
        let fixture = makeFixture(pen: nil)
        fixture.coordinator.start()

        try await waitUntil("observation to start") { fixture.central.isObserving }

        fixture.controller.selectSyncMode(.paused)
        try await waitUntil("observation to stop") { !fixture.central.isObserving }

        // Paused stops the timers as well as the discovery, so even a long wait
        // starts nothing.
        fixture.clock.advance(by: .seconds(1800))
        try await assertNoReads(fixture, after: 0, window: .milliseconds(200))

        // Choosing Delete or Retain is what resumes, and the overdue interval makes
        // the first opportunity immediate.
        fixture.controller.selectSyncMode(.delete)
        try await waitUntil("a read after resuming") { fixture.recorder.startCount == 1 }

        await finish(fixture)
    }

    func testPausedWhileAReadRunsLetsThatReadFinish() async throws {
        let fixture = makeFixture(recorder: CoordinatorRunnerRecorder(holdsAttempts: true))
        fixture.coordinator.start()

        try await waitUntil("the read to start") { fixture.recorder.startCount == 1 }

        fixture.controller.selectSyncMode(.paused)
        fixture.recorder.gate.open()

        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }
        try await waitUntil("observation to stop") { !fixture.central.isObserving }

        // The read finished and reported itself; nothing later starts while Paused.
        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        await finish(fixture)
    }

    func testRelaunchingWhilePausedStartsNoDiscovery() async throws {
        let fixture = makeFixture(mode: .paused)
        fixture.coordinator.start()

        try await assertNoReads(fixture, after: 0, window: .milliseconds(200))

        XCTAssertFalse(fixture.central.isObserving, "Paused must not discover the pen")
        XCTAssertFalse(fixture.central.didScan, "Paused must not scan for the pen")

        await finish(fixture)
    }

    // MARK: - The saved mode authorizes the transfer

    func testSavedDeleteAuthorizesTheDeletingTransferWithoutAConfirmation() async throws {
        let read = TestRead.deletingResult(
            strokes: [TestRead.stroke()],
            packetCount: 1,
            isComplete: true
        )
        let fixture = makeFixture(recorder: CoordinatorRunnerRecorder(read: read))

        // The per-read route would still be waiting for a click.
        XCTAssertTrue(fixture.controller.needsCleanupConfirmation)

        fixture.coordinator.start()
        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }

        let intent = try XCTUnwrap(fixture.recorder.intents.first ?? nil)
        XCTAssertTrue(intent.requestedExport)
        XCTAssertTrue(intent.durablePacketStorageAvailable)
        XCTAssertTrue(try XCTUnwrap(fixture.controller.outcome).isDeletingRead)

        await finish(fixture)
    }

    func testSavedRetainAsksForNoDeletingTransfer() async throws {
        let fixture = makeFixture(mode: .retain)
        fixture.coordinator.start()

        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }

        XCTAssertEqual(fixture.recorder.intents.count, 1)
        XCTAssertNil(fixture.recorder.intents[0], "Sync and Retain must request no deleting transfer")
        XCTAssertEqual(fixture.controller.outcome?.cleanup, .retainedByChoice)

        await finish(fixture)
    }

    func testAModeChangedDuringAReadAppliesToTheNextOne() async throws {
        let read = TestRead.deletingResult(
            strokes: [TestRead.stroke()],
            packetCount: 1,
            isComplete: true
        )
        let fixture = makeFixture(
            recorder: CoordinatorRunnerRecorder(read: read, holdsAttempts: true)
        )
        fixture.coordinator.start()

        try await waitUntil("the first read") { fixture.recorder.startCount == 1 }
        XCTAssertNotNil(fixture.recorder.intents[0], "the saved Delete mode asked for deletion")

        // A setting changed while a read runs cannot reach that read, which already
        // captured its own transfer.
        fixture.controller.selectSyncMode(.retain)
        fixture.recorder.gate.open()

        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }
        fixture.clock.advance(by: .seconds(300))
        try await waitUntil("the next read") { fixture.recorder.startCount == 2 }

        XCTAssertNil(fixture.recorder.intents[1], "the next read follows the saved Retain mode")

        await finish(fixture)
    }

    func testAnAutomaticFallbackNeverReachesTheSeparateDeletionCommand() async throws {
        // No export destination, so the deleting route is closed before the read
        // starts and the automatic sync has to fall back to an ordinary read.
        let library = StubImportCoordinator(
            outcome: .saved(TestRead.save(), export: nil),
            saving: Gate(isOpen: true),
            exporting: Gate(isOpen: true)
        )
        let fixture = makeFixture(
            destination: NoExportDestination(),
            library: library
        )
        fixture.coordinator.start()

        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }

        XCTAssertNil(fixture.recorder.intents[0], "a closed route must not ask for a deleting transfer")
        let outcome = try XCTUnwrap(fixture.controller.outcome)
        XCTAssertTrue(outcome.isSaved, "the fallback still saves the read")
        XCTAssertFalse(outcome.reclaimedPenCopy)
        guard case .skipped(let reason) = outcome.cleanup else {
            return XCTFail("expected a skipped cleanup, got \(outcome.cleanup)")
        }
        XCTAssertTrue(reason.contains("export"), reason)
        let requested = await library.requestedCleanupCount()
        XCTAssertEqual(
            requested,
            0,
            "an automatic sync must never fall back to the separate deletion command"
        )

        await finish(fixture)
    }

    func testAnAutomaticRetryNeverReachesTheSeparateDeletionCommand() async throws {
        // The publication fails on the first attempt, so the completed read offers a
        // retry. The retry publishes from the library and must not ask for a
        // separate deletion command either.
        let failed = PenExportReport(artifacts: [
            PenExportArtifact(
                format: .json,
                path: "/tmp/ncode-s3-o27-b700-p1.json",
                byteCount: 1,
                status: .failed(reason: "the disk is full")
            )
        ])
        let library = StubImportCoordinator(
            outcome: .saved(TestRead.save(), export: failed),
            saving: Gate(isOpen: true),
            exporting: Gate(isOpen: true),
            // The retry succeeds, so the run reaches the branch that decides whether
            // to ask for cleanup rather than falling through to the read's own
            // outcome.
            retryReport: PenExportReport(artifacts: [])
        )
        let fixture = makeFixture(library: library)
        fixture.coordinator.start()

        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }
        XCTAssertTrue(fixture.controller.canRetryExport)

        fixture.controller.retryExport()
        try await waitUntil("the retry to settle") {
            fixture.controller.outcome?.exportSucceeded == true
        }

        let outcome = try XCTUnwrap(fixture.controller.outcome)
        XCTAssertTrue(outcome.exportSucceeded, "the retry published from the library")
        guard case .skipped(let reason) = outcome.cleanup else {
            return XCTFail("expected a skipped cleanup, got \(outcome.cleanup)")
        }
        XCTAssertFalse(
            reason.contains("deletion evidence gate"),
            "an automatic sync reports its own transfer blocker, not the separate command gate"
        )

        let requested = await library.requestedCleanupCount()
        XCTAssertEqual(
            requested,
            0,
            "an automatic retry must never reach the separate deletion command"
        )

        await finish(fixture)
    }

    func testAnAutomaticSyncReportsARefusedTransferWithoutASeparateCommand() async throws {
        // The pen's identity closed the deleting route after the handshake, so the
        // session read non-destructively and named the blocker.
        let refusal = "the deleting-transfer evidence gate is closed for protocol 2.18"
        let read = TestRead.refusedDeletingResult(strokes: [TestRead.stroke()], refusal: refusal)
        let library = StubImportCoordinator(
            outcome: .saved(TestRead.save(), export: nil),
            cleanup: .reclaimed(pageCount: 1),
            saving: Gate(isOpen: true),
            exporting: Gate(isOpen: true)
        )
        let fixture = makeFixture(recorder: CoordinatorRunnerRecorder(read: read), library: library)
        fixture.coordinator.start()

        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }

        XCTAssertNotNil(
            fixture.recorder.intents[0],
            "the saved Delete mode asks for a deleting transfer"
        )
        let outcome = try XCTUnwrap(fixture.controller.outcome)
        XCTAssertFalse(outcome.isDeletingRead, "the refusal makes it an ordinary read")
        XCTAssertTrue(outcome.isSaved, "a refused route must not stop the read being stored")
        XCTAssertFalse(outcome.reclaimedPenCopy)
        XCTAssertEqual(outcome.cleanup, .skipped(reason: refusal))

        let requested = await library.requestedCleanupCount()
        XCTAssertEqual(requested, 0, "a refused deleting route must not request a separate deletion")

        await finish(fixture)
    }

    func testAnAutomaticSyncWithoutDurableStorageKeepsThePensCopy() async throws {
        let library = StubImportCoordinator(
            outcome: .saved(TestRead.save(), export: nil),
            cleanup: .reclaimed(pageCount: 1),
            saving: Gate(isOpen: true),
            exporting: Gate(isOpen: true)
        )
        let fixture = makeFixture(deletingReadStorage: .unavailable, library: library)
        fixture.coordinator.start()

        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }

        XCTAssertNil(
            fixture.recorder.intents[0],
            "no durable packet storage means no deleting transfer"
        )
        let outcome = try XCTUnwrap(fixture.controller.outcome)
        XCTAssertTrue(outcome.isSaved)
        XCTAssertFalse(outcome.reclaimedPenCopy)
        guard case .skipped(let reason) = outcome.cleanup else {
            return XCTFail("expected a skipped cleanup, got \(outcome.cleanup)")
        }
        XCTAssertTrue(reason.contains("durable packet storage"), reason)

        let requested = await library.requestedCleanupCount()
        XCTAssertEqual(requested, 0, "a closed route must not request a separate deletion")

        await finish(fixture)
    }

    func testAnInterruptedAutomaticTransferRequestsNoDeletion() async throws {
        let library = StubImportCoordinator(
            outcome: .saved(TestRead.save(), export: nil),
            saving: Gate(isOpen: true),
            exporting: Gate(isOpen: true)
        )
        let fixture = makeFixture(
            recorder: CoordinatorRunnerRecorder(
                failure: PenSessionError.incompleteTransfer(assembledPacketCount: 3)
            ),
            library: library
        )
        fixture.coordinator.start()

        try await waitUntil("the failure to be reported") { fixture.controller.errorMessage != nil }

        XCTAssertNil(fixture.controller.outcome, "an interrupted transfer is not a completed sync")
        XCTAssertEqual(
            fixture.controller.errorDiagnostic,
            "3 packets arrived before the pen stopped sending."
        )

        let requested = await library.requestedCleanupCount()
        XCTAssertEqual(requested, 0, "an interrupted transfer must not request a deletion")

        await finish(fixture)
    }

    // MARK: - Sync Now

    func testSyncNowReadsThePenWithoutWaitingForDiscoveryOrTheInterval() async throws {
        // No pen is in range and no interval has elapsed, so only the request itself
        // can start this read.
        let fixture = makeFixture(pen: nil)
        fixture.coordinator.start()
        try await waitUntil("observation to start") { fixture.central.isObserving }

        XCTAssertTrue(fixture.coordinator.requestImmediateRead())

        try await waitUntil("the requested read") { fixture.recorder.startCount == 1 }
        try await waitUntil("it to settle") { fixture.controller.outcome != nil }

        XCTAssertTrue(try XCTUnwrap(fixture.controller.outcome).isSaved)

        await finish(fixture)
    }

    func testARequestedReadStopsTheObservationBeforeItScans() async throws {
        let fixture = makeFixture(
            pen: PenPeripheral(id: UUID(), name: penName),
            runner: { central in
                HandoffRunner(central: central, read: TestRead.result(strokes: [TestRead.stroke()]))
            }
        )
        fixture.coordinator.start()

        // The launch read fixes the starting point, so the handoff below belongs to
        // the requested read.
        try await waitUntil("the launch read") { fixture.controller.outcome != nil }
        try await waitUntil("observation to resume") { fixture.central.isObserving }
        let before = fixture.central.events.count

        XCTAssertTrue(fixture.coordinator.requestImmediateRead())
        try await waitUntil("the requested read to scan") {
            fixture.central.events.count > before + 1
        }

        XCTAssertEqual(
            Array(fixture.central.events[before..<(before + 2)]),
            ["stopObservation", "scan"],
            "a requested read takes the radio through the same handoff"
        )

        await finish(fixture)
    }

    func testAnAcceptedRequestIsHeldWhenTheControllerGoesBusyDuringTheHandoff() async throws {
        // The publication fails, so the completed read offers the one action a user can
        // take that makes the controller busy: Retry Export. Its gate stays closed, so
        // the retry is still in flight while the request is handled.
        let retry = Gate()
        let failed = PenExportReport(artifacts: [
            PenExportArtifact(
                format: .json,
                path: "/tmp/ncode-s3-o27-b700-p1.json",
                byteCount: 1,
                status: .failed(reason: "the disk is full")
            )
        ])
        let fixture = makeFixture(
            library: StubImportCoordinator(
                outcome: .saved(TestRead.save(), export: failed),
                saving: Gate(isOpen: true),
                exporting: Gate(isOpen: true),
                retry: retry
            )
        )
        fixture.coordinator.start()

        // The launch read settles with a failed export, which is what offers the retry.
        try await waitUntil("the launch read to settle") { fixture.controller.outcome != nil }
        try await waitUntil("observation to resume") { fixture.central.isObserving }
        XCTAssertTrue(fixture.controller.canRetryExport)

        // The request is accepted while the schedule is parked and the controller is
        // idle, and the retry then runs in the same turn — before the loop resumes — so
        // the controller is already busy by the time the loop reaches the start of the
        // accepted read. That is the window the observation handoff opens in production.
        XCTAssertTrue(fixture.coordinator.requestImmediateRead())
        fixture.controller.retryExport()
        XCTAssertTrue(fixture.controller.isBusy, "the retry is what makes the controller busy")

        // The accepted request is held rather than dropped: the loop must not lose it,
        // and it must not start the schedule's own read in its place.
        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        await retry.open()

        // Nothing but the accepted request can start a read here — no interval has
        // elapsed and the pen in range is not a fresh appearance — so the second read is
        // the request, taken once the controller is free again.
        try await waitUntil("the requested read") { fixture.recorder.startCount == 2 }
        try await waitUntil("it to settle") { fixture.controller.isBusy == false }
        try await assertNoReads(fixture, after: 2, window: .milliseconds(200))

        XCTAssertNotNil(
            fixture.recorder.intents.last,
            "the read started for the request carried the saved-mode Delete transfer intent"
        )

        await finish(fixture)
    }

    func testSyncNowIsRefusedWhileAnAutomaticReadIsRunningAndQueuesNothing() async throws {
        let fixture = makeFixture(recorder: CoordinatorRunnerRecorder(holdsAttempts: true))
        fixture.coordinator.start()

        try await waitUntil("the automatic read") { fixture.recorder.startCount == 1 }

        // The automatic read started first, so it owns the attempt: the request is
        // refused rather than queued behind it.
        XCTAssertFalse(fixture.coordinator.requestImmediateRead())
        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        fixture.recorder.gate.open()
        try await waitUntil("the read to settle") { fixture.controller.outcome != nil }

        // The refusal queued nothing: the read that won stays the only attempt.
        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        await finish(fixture)
    }

    func testSyncNowIsRefusedWhileAPenChoiceIsPendingAndWorksOnceItIsAnswered() async throws {
        let first = PenPeripheral(id: UUID(), name: penName)
        let second = PenPeripheral(id: UUID(), name: penName)
        let recorder = CoordinatorRunnerRecorder()
        let fixture = makeFixture(
            pen: first,
            recorder: recorder,
            runner: { _ in ChoosingRunner(recorder: recorder, candidates: [first, second]) }
        )
        fixture.coordinator.start()

        try await waitUntil("the pen choice") { fixture.controller.isAwaitingChoice }

        // A request cannot start a read that would skip the question about which pen
        // to use.
        XCTAssertFalse(fixture.coordinator.requestImmediateRead())
        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        fixture.controller.choosePen(second)
        try await waitUntil("the chosen read to settle") { fixture.controller.outcome != nil }
        try await waitUntil("observation to resume") { fixture.central.isObserving }

        XCTAssertTrue(fixture.coordinator.requestImmediateRead())
        try await waitUntil("the requested read") { recorder.startCount == 3 }

        await finish(fixture)
    }

    func testASecondSyncNowClickStartsNoSecondRead() async throws {
        let fixture = makeFixture(pen: nil)
        fixture.coordinator.start()
        try await waitUntil("observation to start") { fixture.central.isObserving }

        XCTAssertTrue(fixture.coordinator.requestImmediateRead())
        XCTAssertFalse(fixture.coordinator.requestImmediateRead())
        XCTAssertFalse(fixture.coordinator.requestImmediateRead())

        try await waitUntil("the requested read") { fixture.recorder.startCount == 1 }
        try await waitUntil("it to settle") { fixture.controller.outcome != nil }
        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        await finish(fixture)
    }

    func testARequestedReadReAnchorsTheNextAutomaticInterval() async throws {
        let fixture = makeFixture(pen: nil)
        fixture.coordinator.start()
        try await waitUntil("observation to start") { fixture.central.isObserving }

        // Two minutes into the five-minute interval, the user asks for a read of
        // their own.
        fixture.clock.advance(by: .seconds(120))
        XCTAssertTrue(fixture.coordinator.requestImmediateRead())
        try await waitUntil("the requested read") { fixture.recorder.startCount == 1 }
        try await waitUntil("it to settle") { fixture.controller.outcome != nil }

        // The next interval is measured from that read rather than from the schedule's
        // own launch, so the deadline it replaced is not what starts the next attempt.
        fixture.clock.advance(by: .seconds(299))
        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))

        fixture.clock.advance(by: .seconds(1))
        try await waitUntil("the interval read") { fixture.recorder.startCount == 2 }

        await finish(fixture)
    }

    func testSyncNowRunsOneRetainingReadWhilePausedAndLeavesItPaused() async throws {
        let fixture = makeFixture(mode: .paused)
        fixture.coordinator.start()

        // The paused schedule stops its observation before it waits for a wake-up, and
        // nothing else it does is observable, so that is what says it can accept a
        // request.
        try await waitUntil("the paused schedule to wait") { fixture.central.didStopObservation }
        XCTAssertFalse(fixture.central.isObserving, "Paused must not discover the pen")

        XCTAssertTrue(fixture.coordinator.requestImmediateRead())
        try await waitUntil("the requested read") { fixture.recorder.startCount == 1 }
        try await waitUntil("it to settle") { fixture.controller.outcome != nil }

        XCTAssertNil(
            fixture.recorder.intents[0],
            "a paused request asks for no deleting transfer"
        )
        XCTAssertEqual(
            fixture.controller.outcome?.cleanup,
            .retainedByChoice,
            "the one read Pause allows keeps the pen's copy"
        )
        XCTAssertEqual(fixture.controller.syncMode, .paused, "the saved setting is left alone")
        XCTAssertEqual(fixture.controller.menuStatus, .paused)

        // Paused stayed paused: the observation is not running and no interval starts
        // another read.
        fixture.clock.advance(by: .seconds(1800))
        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))
        XCTAssertFalse(fixture.central.isObserving)

        // Choosing a mode is what resumes the schedule.
        fixture.controller.selectSyncMode(.retain)
        try await waitUntil("a read after resuming") { fixture.recorder.startCount == 2 }

        await finish(fixture)
    }

    func testARequestedReadKeepsTheModeItWasAcceptedUnder() async throws {
        let fixture = makeFixture(mode: .paused, pen: nil)
        fixture.coordinator.start()
        try await waitUntil("the paused schedule to wait") { fixture.central.didStopObservation }

        // Accepted while Pause is saved, and the user selects Delete before the read
        // starts: the read keeps what they saw, and the new mode is what is saved.
        XCTAssertTrue(fixture.coordinator.requestImmediateRead())
        fixture.controller.selectSyncMode(.delete)
        try await waitUntil("the requested read to settle") { fixture.controller.outcome != nil }

        try await assertNoReads(fixture, after: 1, window: .milliseconds(200))
        XCTAssertNil(
            fixture.recorder.intents[0],
            "the mode captured at acceptance was Pause, so no deleting transfer is asked for"
        )
        XCTAssertEqual(fixture.controller.outcome?.cleanup, .retainedByChoice)
        XCTAssertEqual(fixture.controller.syncMode, .delete)

        await finish(fixture)
    }

    // MARK: - Helpers

    private struct Fixture {
        let controller: PenSyncController
        let coordinator: PenSyncCoordinator
        let central: FakePenBluetoothCentral
        let clock: FakePenSyncClock
        let recorder: CoordinatorRunnerRecorder
        let defaults: UserDefaults
        let suiteName: String
        let exportRoot: URL
    }

    private func makeFixture(
        mode: PenSyncMode = .delete,
        interval: PenSyncInterval = .fiveMinutes,
        pen: PenPeripheral? = PenPeripheral(
            id: UUID(),
            name: CoreBluetoothPenTransport.advertisedName
        ),
        recorder: CoordinatorRunnerRecorder = CoordinatorRunnerRecorder(),
        runner: (@Sendable (FakePenBluetoothCentral) -> any PenSyncRunning)? = nil,
        destination: (any PenExportDestinationProviding)? = nil,
        deletingReadStorage: PenDeletingReadStorage = .stub,
        library: (any PenImportCoordinator)? = nil
    ) -> Fixture {
        let suiteName = "NeoBridgeCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = PenSyncPreferences(defaults: defaults)
        preferences.mode = mode
        preferences.interval = interval

        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("neobridge-coordinator-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: exportRoot,
            withIntermediateDirectories: true
        )

        let central = FakePenBluetoothCentral(advertisedPeripherals: pen.map { [$0] } ?? [])
        let clock = FakePenSyncClock()
        let factory =
            runner.map { make in PenSyncRunnerFactory { _ in make(central) } }
            ?? PenSyncRunnerFactory { _ in CoordinatorRunner(recorder: recorder) }

        let controller = PenSyncController(
            runners: factory,
            library: library
                ?? StubImportCoordinator(
                    outcome: .saved(TestRead.save(), export: nil),
                    saving: Gate(isOpen: true),
                    exporting: Gate(isOpen: true)
                ),
            destination: destination ?? FixedExportDestination(directory: exportRoot.path),
            deletingReadStorage: deletingReadStorage,
            preferences: preferences
        )

        return Fixture(
            controller: controller,
            coordinator: PenSyncCoordinator(central: central, controller: controller, clock: clock),
            central: central,
            clock: clock,
            recorder: recorder,
            defaults: defaults,
            suiteName: suiteName,
            exportRoot: exportRoot
        )
    }

    /// Ends the schedule and removes the temporary state it used.
    private func finish(_ fixture: Fixture) async {
        fixture.recorder.gate.open()
        await fixture.coordinator.stop()
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.exportRoot)
    }

    /// Waits until a condition holds.
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the schedule never reached: \(description)")
    }

    /// Proves the schedule starts no further read within a bounded window.
    ///
    /// The window is what makes "nothing more happened" meaningful: the schedule's
    /// continuation after a read runs promptly, so a read that was going to start
    /// would appear well inside it.
    private func assertNoReads(
        _ fixture: Fixture,
        after expected: Int,
        window: Duration
    ) async throws {
        let deadline = ContinuousClock.now + window
        while ContinuousClock.now < deadline {
            XCTAssertEqual(
                fixture.recorder.startCount,
                expected,
                "the schedule started a read it should not have"
            )
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
