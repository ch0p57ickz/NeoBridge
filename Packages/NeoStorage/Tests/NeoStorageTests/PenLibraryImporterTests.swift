import Foundation
import NeoCore
import XCTest

@testable import NeoStorage

/// Tests for the verified importer: durable batches, replay-safe commits, export
/// reporting, publication retries, and the dormant cleanup journal.
final class PenLibraryImporterTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory.remove()
        directory = nil
    }

    // MARK: - Helpers

    private let page = PageIdentity(section: 3, owner: 27, book: 700, page: 1)

    private func stroke(
        offset: Int64,
        page: PageIdentity? = nil,
        origin: PenOriginTime = .reliable(milliseconds: 1_700_000_000_000)
    ) -> Stroke {
        Stroke(
            page: page ?? self.page,
            originTime: origin,
            points: [
                PenPoint(x: Int32(offset), y: 0, penTimeOffsetMilliseconds: offset, pressure: 3)
            ],
            source: .offline
        )
    }

    private func transfer(_ strokes: [Stroke]) -> PenReadTransfer {
        PenReadTransfer(strokes: strokes, noteCount: 1)
    }

    private func request(pages: [PageIdentity]? = nil) -> PenExportRequest {
        PenExportRequest(
            pages: pages ?? [page],
            destinationDirectory: "/tmp/exports"
        )
    }

    private func makeImporter(
        library: SQLitePenLibrary,
        publisher: StubExportPublisher = StubExportPublisher(),
        policy: PenCleanupPolicy = PenCleanupPolicy(),
        journal: (any PenCleanupJournal)? = nil
    ) -> PenLibraryImporter {
        PenLibraryImporter(
            store: library,
            batches: library,
            journal: journal ?? library,
            publisher: publisher,
            policy: policy
        )
    }

    // MARK: - Import

    func testImportStoresEveryStrokeAndPublishesThreeFiles() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let publisher = StubExportPublisher()
        let importer = makeImporter(library: library, publisher: publisher)

        let outcome = try await importer.importRead(
            transfer([stroke(offset: 0), stroke(offset: 4)]),
            export: request()
        )

        let save = try XCTUnwrap(outcome.save)
        XCTAssertEqual(save.strokeCount, 2)
        XCTAssertEqual(save.insertion.addedStrokeCount, 2)
        XCTAssertEqual(save.pages, [page])

        let export = try XCTUnwrap(outcome.export)
        XCTAssertTrue(export.succeeded)
        XCTAssertEqual(export.artifacts.map(\.format), [.json, .svg, .markdown])

        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 2)

        let calls = await publisher.calls.allRequests
        XCTAssertEqual(calls.count, 1)
        let content = await publisher.calls.allContent
        XCTAssertEqual(content.first?.first?.strokes.count, 2)
    }

    func testReplayedImportAddsNoDuplicateStroke() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let importer = makeImporter(library: library)
        let read = transfer([stroke(offset: 0), stroke(offset: 9)])

        let first = try await importer.importRead(read, export: request())
        let second = try await importer.importRead(read, export: request())

        XCTAssertEqual(first.save?.insertion.addedStrokeCount, 2)
        XCTAssertEqual(second.save?.insertion.addedStrokeCount, 0)
        XCTAssertEqual(second.save?.insertion.duplicateStrokeCount, 2)

        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 2, "a replay must not duplicate reliable strokes")
    }

    func testImportWithNoStrokesStoresNothingAndPublishesNothing() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let publisher = StubExportPublisher()
        let importer = makeImporter(library: library, publisher: publisher)

        let outcome = try await importer.importRead(
            PenReadTransfer(strokes: [], noteCount: 0),
            export: request()
        )

        XCTAssertEqual(outcome, .noStrokesFound)
        let pages = try await library.pages()
        XCTAssertEqual(pages, [])
        let calls = await publisher.calls.allRequests
        XCTAssertEqual(calls, [], "an empty read must not publish a file")
    }

    func testExportFailureIsReportedSeparatelyFromTheSave() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let importer = makeImporter(
            library: library,
            publisher: StubExportPublisher(failures: [.svg: "the destination is read-only"])
        )

        let outcome = try await importer.importRead(transfer([stroke(offset: 0)]), export: request())

        XCTAssertTrue(outcome.isSaved, "the library save stands even when a file fails")
        let export = try XCTUnwrap(outcome.export)
        XCTAssertFalse(export.succeeded)
        XCTAssertEqual(export.failed.map(\.format), [.svg])
        XCTAssertEqual(export.published.map(\.format), [.json, .markdown])
        XCTAssertEqual(export.failureMessages, ["the destination is read-only"])

        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 1, "a failed publication must preserve committed data")
    }

    func testRetryPublishesTheCommittedRowsWithoutImportingAgain() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let failing = StubExportPublisher(failures: [.json: "disk full"])
        let importer = makeImporter(library: library, publisher: failing)

        let outcome = try await importer.importRead(transfer([stroke(offset: 0)]), export: request())
        let save = try XCTUnwrap(outcome.save)
        XCTAssertEqual(outcome.export?.failed.count, 1)

        // A second importer over the same library retries from the stored rows.
        let retry = try await makeImporter(library: library).retryExport(
            batchID: save.batchID,
            request: request()
        )

        XCTAssertTrue(retry.succeeded)
        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 1, "a retry must not store the read twice")
    }

    func testImportWithoutAnExportRequestLeavesTheBatchCommitted() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let importer = makeImporter(library: library)

        let outcome = try await importer.importRead(transfer([stroke(offset: 0)]), export: nil)
        let save = try XCTUnwrap(outcome.save)

        XCTAssertNil(outcome.export)
        let record = try await library.batch(id: save.batchID)
        XCTAssertEqual(record?.state, .committed)
        XCTAssertEqual(record?.isPublicationRetryable, true)
    }

    func testAPublishedBatchCanPublishAgainForItsFiles() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let publisher = StubExportPublisher()
        let importer = makeImporter(library: library, publisher: publisher)

        let outcome = try await importer.importRead(transfer([stroke(offset: 0)]), export: request())
        let save = try XCTUnwrap(outcome.save)

        // A published batch is publication-retryable, so a later export re-renders
        // its files instead of failing on a terminal state.
        let report = try await importer.retryExport(batchID: save.batchID, request: request())
        XCTAssertTrue(report.succeeded)
        let calls = await publisher.calls.allRequests
        XCTAssertEqual(calls.count, 2)
        let record = try await library.batch(id: save.batchID)
        XCTAssertEqual(record?.state, .published)
    }

    func testAFullyPublishedImportIsRecordedAsPublished() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let importer = makeImporter(library: library)

        let outcome = try await importer.importRead(transfer([stroke(offset: 0)]), export: request())
        let save = try XCTUnwrap(outcome.save)

        let record = try await library.batch(id: save.batchID)
        XCTAssertEqual(record?.state, .published)
    }

    // MARK: - Failure paths

    func testAStorageFailureIsNotReportedAsSaved() async throws {
        let library = try SQLitePenLibrary(
            url: directory.file("library.sqlite"),
            faultInjection: { index in
                if index == 1 { throw InjectedFailure.stopped }
            }
        )
        let importer = makeImporter(library: library)

        do {
            let outcome = try await importer.importRead(
                transfer([stroke(offset: 0), stroke(offset: 1)]),
                export: request()
            )
            XCTFail("expected the storage failure to surface, got \(outcome)")
        } catch {
            XCTAssertEqual(error as? InjectedFailure, .stopped)
        }

        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored, [], "no stroke may be stored when the batch fails")
        let committed = try await library.batches(in: .committed)
        XCTAssertEqual(committed, [])
        let failed = try await library.batches(in: .failed)
        XCTAssertEqual(failed.count, 1, "the failed batch is recorded so it is not mistaken for a save")
    }

    func testAnUnknownBatchCannotPublish() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let importer = makeImporter(library: library)
        let unknown = UUID()

        do {
            _ = try await importer.retryExport(batchID: unknown, request: request())
            XCTFail("expected an unknown batch to be refused")
        } catch {
            XCTAssertEqual(
                error as? StorageError,
                .batchNotReady(batchID: unknown, state: nil)
            )
        }
    }

    func testABatchThatNeverCommittedCannotPublish() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let importer = makeImporter(library: library)

        let batch = try await importer.collect([stroke(offset: 0)])

        do {
            _ = try await importer.publish(batch.id, request: request())
            XCTFail("expected an uncommitted batch to be refused")
        } catch {
            guard case .batchNotReady(_, let state) = error as? StorageError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(state, .collecting)
        }
    }

    func testARestartedProcessRefusesToCommitACollectedBatch() async throws {
        let url = directory.file("library.sqlite")
        let first = makeImporter(library: try SQLitePenLibrary(url: url))
        let batch = try await first.collect([stroke(offset: 0)])

        // The in-memory buffer is gone after a restart, so the read must be
        // taken from the pen again instead of committing a partial transfer.
        let second = makeImporter(library: try SQLitePenLibrary(url: url))
        do {
            try await second.commit(batch.id)
            XCTFail("expected the collected strokes to be unavailable")
        } catch {
            XCTAssertEqual(
                error as? StorageError,
                .collectedStrokesUnavailable(batchID: batch.id)
            )
        }

        let library = try SQLitePenLibrary(url: url)
        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored, [])
        let record = try await library.batch(id: batch.id)
        XCTAssertEqual(record?.state, .collecting, "an interrupted transfer stays uncommitted")
    }

    func testACommittedBatchDoesNotRetainItsStrokesInMemory() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let importer = makeImporter(library: library)

        let batch = try await importer.collect([stroke(offset: 0)])
        try await importer.validate(batch.id)
        try await importer.commit(batch.id)

        // The read's point data is released once the insert resolves, so the
        // batch cannot be committed a second time from a stale buffer.
        do {
            try await importer.commit(batch.id)
            XCTFail("expected the collected strokes to be gone after a commit")
        } catch {
            XCTAssertEqual(
                error as? StorageError,
                .collectedStrokesUnavailable(batchID: batch.id)
            )
        }

        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 1)
    }

    func testACommittedBatchPublishesAfterARestart() async throws {
        let url = directory.file("library.sqlite")
        let save: PenLibrarySave
        do {
            let importer = makeImporter(
                library: try SQLitePenLibrary(url: url),
                publisher: StubExportPublisher(failures: [.json: "disk full"])
            )
            let outcome = try await importer.importRead(
                transfer([stroke(offset: 0)]),
                export: request()
            )
            save = try XCTUnwrap(outcome.save)
            XCTAssertEqual(outcome.export?.succeeded, false)
        }

        let importer = makeImporter(library: try SQLitePenLibrary(url: url))
        let report = try await importer.retryExport(batchID: save.batchID, request: request())
        XCTAssertTrue(report.succeeded)

        let library = try SQLitePenLibrary(url: url)
        let record = try await library.batch(id: save.batchID)
        XCTAssertEqual(record?.state, .published)
    }

    func testRetryFallsBackToTheBatchPagesWhenTheRequestNamesNone() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let publisher = StubExportPublisher()
        let importer = makeImporter(library: library, publisher: publisher)

        let outcome = try await importer.importRead(transfer([stroke(offset: 0)]), export: nil)
        let save = try XCTUnwrap(outcome.save)

        let report = try await importer.retryExport(
            batchID: save.batchID,
            request: PenExportRequest(formats: [.json], pages: [], destinationDirectory: "/tmp/exports")
        )

        XCTAssertTrue(report.succeeded)
        let content = await publisher.calls.allContent
        XCTAssertEqual(content.last?.map(\.page), [page])
    }

    // MARK: - Pen cleanup

    /// The evidence record that opens the deletion gate for one scope.
    private func openEvidence(target: PenDeletionTarget = .note) -> PenDeletionEvidence {
        PenDeletionEvidence(
            target: target,
            verdicts: Dictionary(
                uniqueKeysWithValues: PenDeletionCondition.allCases.map { ($0, .safe) }
            )
        )
    }

    /// Imports and publishes one stroke, returning its batch identifier.
    private func publishedBatch(_ importer: PenLibraryImporter) async throws -> UUID {
        let outcome = try await importer.importRead(transfer([stroke(offset: 0)]), export: request())
        return try XCTUnwrap(outcome.save?.batchID)
    }

    func testRetentionChoiceRecordsNothingAndSendsNothing() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)

        let outcome = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .keepOnPen, sender: sender)
        )

        XCTAssertEqual(outcome, .retainedByChoice)
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states, [], "retention must not journal a cleanup request")
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "retention must not send a deletion command")
    }

    func testCleanupIsSkippedWhileTheGateIsClosed() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(library: library)
        let batchID = try await publishedBatch(importer)

        let outcome = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        guard case .skipped(let reason) = outcome else {
            return XCTFail("expected a skipped cleanup, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("deletion evidence gate"), reason)
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states, [], "a closed gate must record no cleanup request")
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "a closed gate must not send a deletion command")
    }

    func testCleanupIsSkippedForAnUncommittedOrUnpublishedBatch() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )

        let collected = try await importer.collect([stroke(offset: 0)])
        let pending = try await importer.requestCleanup(
            collected.id,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        guard case .skipped = pending else {
            return XCTFail("expected an uncommitted batch to be skipped, got \(pending)")
        }

        // A failed export leaves the batch committed, not published.
        let failing = makeImporter(
            library: library,
            publisher: StubExportPublisher(failures: [.json: "disk full"]),
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let outcome = try await failing.importRead(transfer([stroke(offset: 1)]), export: request())
        let save = try XCTUnwrap(outcome.save)
        let unpublished = try await failing.requestCleanup(
            save.batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        guard case .skipped = unpublished else {
            return XCTFail("expected a failed export to be skipped, got \(unpublished)")
        }

        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "neither batch may reach the pen as a deletion")
    }

    func testAPublishedBatchIsDeletedAndConfirmed() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)

        let outcome = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        XCTAssertEqual(outcome, .reclaimed(pageCount: 1))
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states, [.prepared, .requested, .confirmed])

        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.batchID, batchID)
        XCTAssertEqual(sent.first?.target, .note)
        XCTAssertEqual(sent.first?.pages, [page], "only the batch's own committed pages may be deleted")
    }

    func testTheScopeIsRecordedBeforeAnythingIsSent() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let probe = CleanupStateProbe()
        // The sender inspects the durable journal at the moment of the send, so a
        // scope that was not recorded first would be visible here.
        let sender = StubDeletionSender(outcome: { scope in
            await probe.record(try? await library.latestState(batchID: scope.batchID))
            return .confirmed(scope)
        })
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)

        _ = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        let stateAtSend = await probe.state
        XCTAssertEqual(stateAtSend, .requested, "the request must be durable before the bytes are sent")
    }

    func testAReadWithNoRequestedExportRetainsThePenCopy() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )

        // No export was requested, so the batch stays committed.
        let outcome = try await importer.importRead(transfer([stroke(offset: 0)]), export: nil)
        let batchID = try XCTUnwrap(outcome.save?.batchID)

        let cleanup = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        guard case .skipped(let reason) = cleanup else {
            return XCTFail("expected a read with no published export to be retained, got \(cleanup)")
        }
        XCTAssertTrue(reason.contains("no export published in full"), reason)
        XCTAssertTrue(reason.contains("committed"), reason)
        XCTAssertTrue(reason.contains("only copy"), "the reason must say why it is retained: \(reason)")
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "nothing may be sent for a read with no published export")
    }

    func testAConfirmedRequestIsNeverSentAgain() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)

        let first = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        XCTAssertEqual(first, .reclaimed(pageCount: 1))

        // The request is terminal once the pen proved removal: a second request
        // reports the same result instead of sending the command again.
        let second = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        XCTAssertEqual(second, .reclaimed(pageCount: 1))

        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent.count, 1, "a confirmed request must never be sent again")
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states, [.prepared, .requested, .confirmed])
    }

    func testAConfirmedDeletionIsReportedReclaimedEvenWhenTheJournalWriteFails() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence()),
            journal: FailingCleanupJournal(inner: library, failing: .confirmed)
        )
        let batchID = try await publishedBatch(importer)

        let outcome = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        // The pen proved the removal, so the read is reported as reclaimed: a
        // journal that could not record it must not turn the result into "the pen
        // kept its strokes" for data the pen removed.
        XCTAssertEqual(outcome, .reclaimed(pageCount: 1))
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent.count, 1)
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states, [.prepared, .requested], "the unrecorded confirmation stays outstanding")
    }

    func testASecondRequestForAReadInFlightSendsNoSecondDeletion() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let gate = InputGate()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence()),
            journal: GatedCleanupJournal(inner: library, gate: gate)
        )
        let batchID = try await publishedBatch(importer)
        let sender = StubDeletionSender()

        // The first request is held between its checks and its journal write, so the
        // journal still has no row when the second one runs: nothing but an in-flight
        // guard can stop the second from sending the same deletion again.
        let first = Task {
            try await importer.requestCleanup(
                batchID,
                request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
            )
        }
        await gate.waitUntilEntered()

        let second = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        guard case .outstanding(let reason) = second else {
            return XCTFail("expected a second request in flight to stay outstanding, got \(second)")
        }
        XCTAssertTrue(reason.contains("already in flight"), reason)

        await gate.open()
        let firstOutcome = try await first.value
        XCTAssertEqual(firstOutcome, .reclaimed(pageCount: 1))

        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent.count, 1, "one read must never be deleted twice")
    }

    func testACancelledSyncSendsNoDeletion() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let gate = InputGate()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence()),
            journal: GatedCleanupJournal(inner: library, gate: gate)
        )
        let batchID = try await publishedBatch(importer)
        let sender = StubDeletionSender()

        // The user ends the sync while the request waits for its journal write, so
        // the deletion must not be sent even though the request was recorded.
        let task = Task {
            try await importer.requestCleanup(
                batchID,
                request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
            )
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        let outcome = try await task.value
        guard case .outstanding(let reason) = outcome else {
            return XCTFail("expected a cancelled sync to stay outstanding, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("cancelled"), reason)

        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "a cancelled sync must put nothing on the wire")
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(
            states,
            [.prepared, .requested],
            "a request cancelled before its send stays recorded and unconfirmed"
        )
    }

    func testAConfirmationWithoutARecordedScopeIsReportedAsOutstanding() async throws {
        let url = directory.file("library.sqlite")
        let library = try SQLitePenLibrary(url: url)
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)

        // A journal that claims confirmation without the scope it confirmed cannot
        // substantiate a reclamation, so the removal is reported as unproven rather
        // than a page count being invented for it.
        do {
            let connection = try SQLiteConnection(path: url.path)
            let statement = try connection.prepare(
                "INSERT INTO cleanup_journal (batch_id, state) VALUES (?, 'confirmed')"
            )
            try statement.bind(1, batchID.uuidString)
            try statement.run()
        }

        let outcome = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        guard case .outstanding(let reason) = outcome else {
            return XCTFail("expected an unsubstantiated confirmation to be outstanding, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("scope is missing"), reason)
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "nothing may be sent for an unsubstantiated confirmation")
    }

    func testAnUnreadableJournalStateIsReportedAsOutstanding() async throws {
        let url = directory.file("library.sqlite")
        let library = try SQLitePenLibrary(url: url)
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)

        // A state this build cannot read says nothing about whether a deletion was
        // already sent, so it is reported as an unknown effect, never as "no request"
        // and never repeated.
        do {
            let connection = try SQLiteConnection(path: url.path)
            let statement = try connection.prepare(
                "INSERT INTO cleanup_journal (batch_id, state) VALUES (?, 'unknown')"
            )
            try statement.bind(1, batchID.uuidString)
            try statement.run()
        }

        let outcome = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        guard case .outstanding(let reason) = outcome else {
            return XCTFail("expected an unreadable state to be outstanding, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("cannot be read back"), reason)
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "an unknown effect must never be sent again")
    }

    func testAReadWithNoPagesIsNeverReclaimed() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )

        // The public import steps allow a batch with no page at all, so the cleanup
        // path refuses it instead of journaling and sending an empty scope.
        let batch = try await importer.collect([])
        try await importer.validate(batch.id)
        try await importer.commit(batch.id)
        let report = try await importer.publish(batch.id, request: request(pages: []))
        XCTAssertTrue(report.succeeded)

        let outcome = try await importer.requestCleanup(
            batch.id,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        guard case .skipped(let reason) = outcome else {
            return XCTFail("expected a read with no pages to be retained, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("stored no pages"), reason)
        let states = try await library.recordedStates(batchID: batch.id)
        XCTAssertEqual(states, [], "an empty scope must never be journaled")
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "an empty scope must never reach the pen")
    }

    func testASendFailureLeavesTheRequestOutstanding() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = FailingDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)

        let outcome = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        // The request was journaled as requested before the send, so a failed send
        // is an unknown effect, not a known refusal.
        guard case .outstanding = outcome else {
            return XCTFail("expected a failed send to stay outstanding, got \(outcome)")
        }
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states, [.prepared, .requested], "a failed send must not confirm")
        let outstanding = try await importer.outstandingCleanups()
        XCTAssertEqual(outstanding.map(\.batchID), [batchID])
    }

    func testAnUnconfirmedRequestStaysOutstandingAndIsNotRepeated() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender(outcome: { .unacknowledged($0) })
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)

        let first = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        guard case .outstanding = first else {
            return XCTFail("expected an unacknowledged request to stay outstanding, got \(first)")
        }
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states, [.prepared, .requested], "an unproven outcome must not confirm")

        // A second sync must not send the command again.
        let second = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        guard case .outstanding = second else {
            return XCTFail("expected the second attempt to report outstanding, got \(second)")
        }
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent.count, 1, "an outstanding request must never be repeated automatically")
    }

    func testAMismatchedConfirmationLeavesTheRequestOutstanding() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender(outcome: { scope in
            .confirmed(PenDeletionScope(batchID: scope.batchID, target: scope.target, pages: []))
        })
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)

        let outcome = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        guard case .outstanding = outcome else {
            return XCTFail("a confirmation for another scope must not confirm, got \(outcome)")
        }
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states, [.prepared, .requested])
    }

    func testARefusedRequestStaysOutstanding() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender(outcome: { .refused(scope: $0, code: 0x05) })
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)

        let outcome = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        guard case .outstanding(let reason) = outcome else {
            return XCTFail("expected a refused request to stay outstanding, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("refused"), reason)
    }

    func testNoSenderIsReportedAsSkipped() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)

        let outcome = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: nil)
        )

        guard case .skipped(let reason) = outcome else {
            return XCTFail("expected a missing link to be skipped, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("no pen link"), reason)
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states, [], "a request that cannot be sent must record nothing")
    }

    func testCleanupIsRefusedWhenTheScopeSharesAPageWithAnIncompleteSync() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )

        // The first read publishes; the second touches the same page but its
        // export fails, so its pen data is not confirmed.
        let publishedID = try await publishedBatch(importer)
        let failing = makeImporter(
            library: library,
            publisher: StubExportPublisher(failures: [.json: "disk full"]),
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let failed = try await failing.importRead(transfer([stroke(offset: 9)]), export: request())
        let failedID = try XCTUnwrap(failed.save?.batchID)

        let outcome = try await importer.requestCleanup(
            publishedID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        guard case .skipped(let reason) = outcome else {
            return XCTFail("expected an overlapping scope to be retained, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("has not completed"), reason)
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "an overlapping scope must not reach the pen")

        // The incomplete read is refused for its own reason as well.
        let refused = try await failing.requestCleanup(
            failedID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        guard case .skipped = refused else {
            return XCTFail("expected the failed read to be retained, got \(refused)")
        }
    }

    func testCleanupRunsForACompletedNoteWhosePagesAreItsOwn() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender()
        let second = PageIdentity(section: 3, owner: 27, book: 700, page: 2)
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )

        let published = try await importer.importRead(transfer([stroke(offset: 0)]), export: request())
        let publishedID = try XCTUnwrap(published.save?.batchID)

        // A later read on a different page fails to publish.
        let failing = makeImporter(
            library: library,
            publisher: StubExportPublisher(failures: [.json: "disk full"]),
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        _ = try await failing.importRead(
            transfer([stroke(offset: 9, page: second)]),
            export: request(pages: [second])
        )

        let outcome = try await importer.requestCleanup(
            publishedID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        XCTAssertEqual(outcome, .reclaimed(pageCount: 1))
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent.first?.pages, [page], "only the completed note's own page may be deleted")
    }

    // MARK: - Resolving an outstanding request

    func testResolveCleanupConfirmsOnlyWhenEveryRecordedPageIsGone() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let second = PageIdentity(section: 3, owner: 27, book: 700, page: 2)
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence(target: .page))
        )
        let sender = StubDeletionSender(outcome: { .unacknowledged($0) })

        let outcome = try await importer.importRead(
            transfer([stroke(offset: 0), stroke(offset: 5, page: second)]),
            export: request(pages: [page, second])
        )
        let batchID = try XCTUnwrap(outcome.save?.batchID)
        _ = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        let recorded = try await library.recordedScope(batchID: batchID)
        let scope = try XCTUnwrap(recorded)

        // One page still on the pen keeps the whole request outstanding.
        let partial = try await importer.resolveCleanup(scope, storedPages: [page])
        guard case .outstanding = partial else {
            return XCTFail("expected a page still on the pen to stay outstanding, got \(partial)")
        }

        // Every recorded page gone is an unambiguous confirmation.
        let complete = try await importer.resolveCleanup(scope, storedPages: [PageIdentity]())
        XCTAssertEqual(complete, .reclaimed(pageCount: 2))
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states.last, .confirmed)
    }

    func testResolveCleanupNeverConfirmsWithoutThePensWholeInventory() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender(outcome: { .unacknowledged($0) })
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)
        _ = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        let recorded = try await library.recordedScope(batchID: batchID)
        let scope = try XCTUnwrap(recorded)

        // Neither a read that stopped early nor one that returned only the pages it
        // had to transfer is an inventory of the pen: in both cases a page the read
        // did not return may still be on the pen, so the absence of a page proves
        // nothing and the caller passes no inventory at all.
        let outcome = try await importer.resolveCleanup(scope, storedPages: nil)

        guard case .outstanding(let reason) = outcome else {
            return XCTFail("expected a read without the inventory to leave it outstanding, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("whole inventory"), reason)
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states.last, .requested, "a read without the inventory must not confirm")
    }

    func testResolveCleanupUsesTheDurableScopeNotTheCallersPages() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender(outcome: { .unacknowledged($0) })
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)
        _ = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        // The caller's scope carries no page, but the recorded scope does, so the
        // recorded page still has to be gone before the request is confirmed.
        let narrow = PenDeletionScope(batchID: batchID, target: .note, pages: [])
        let stillThere = try await importer.resolveCleanup(narrow, storedPages: [page])
        guard case .outstanding = stillThere else {
            return XCTFail("expected the recorded page to keep the request open, got \(stillThere)")
        }

        let gone = try await importer.resolveCleanup(narrow, storedPages: [PageIdentity]())
        XCTAssertEqual(gone, .reclaimed(pageCount: 1), "the recorded page count is authoritative")
    }

    func testResolveCleanupIgnoresARequestThatIsNotOutstanding() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let importer = makeImporter(library: library)
        let scope = PenDeletionScope(batchID: UUID(), target: .note, pages: [page])

        let outcome = try await importer.resolveCleanup(scope, storedPages: [PageIdentity]())

        guard case .skipped = outcome else {
            return XCTFail("expected an unknown request to be skipped, got \(outcome)")
        }
        let states = try await library.recordedStates(batchID: scope.batchID)
        XCTAssertEqual(states, [], "resolving an unknown request must record nothing")
    }

    func testResolveCleanupDoesNotTreatAMissingScopeAsNoRequest() async throws {
        let url = directory.file("library.sqlite")
        let library = try SQLitePenLibrary(url: url)
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)

        // A requested state without the scope it recorded is a journal this build
        // cannot trust, so it is not read as "no request".
        do {
            let connection = try SQLiteConnection(path: url.path)
            let statement = try connection.prepare(
                "INSERT INTO cleanup_journal (batch_id, state) VALUES (?, 'requested')"
            )
            try statement.bind(1, batchID.uuidString)
            try statement.run()
        }

        let scope = PenDeletionScope(batchID: batchID, target: .note, pages: [page])
        let outcome = try await importer.resolveCleanup(scope, storedPages: [PageIdentity]())

        guard case .outstanding(let reason) = outcome else {
            return XCTFail("expected a missing scope to stay outstanding, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("scope is missing"), reason)
        let states = try await library.recordedStates(batchID: batchID)
        XCTAssertEqual(states, [.requested], "a missing scope must not confirm anything")
    }

    func testOutstandingCleanupsListTheRequestedScopes() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let sender = StubDeletionSender(outcome: { .unacknowledged($0) })
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(evidence: openEvidence())
        )
        let batchID = try await publishedBatch(importer)
        _ = try await importer.requestCleanup(
            batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        let outstanding = try await importer.outstandingCleanups()
        XCTAssertEqual(outstanding.map(\.batchID), [batchID])
    }
}
