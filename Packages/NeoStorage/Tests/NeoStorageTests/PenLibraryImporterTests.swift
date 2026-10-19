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
        policy: PenCleanupPolicy = PenCleanupPolicy()
    ) -> PenLibraryImporter {
        PenLibraryImporter(
            store: library,
            batches: library,
            journal: library,
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

    func testAFullyPublishedImportIsAcknowledgedAndRecordedAsPublished() async throws {
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

    // MARK: - Pen retention

    func testKeepOnPenRecordsNoCleanupRequest() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let importer = makeImporter(library: library)

        let outcome = try await importer.importRead(transfer([stroke(offset: 0)]), export: request())
        let save = try XCTUnwrap(outcome.save)

        let states = try await library.recordedStates(batchID: save.batchID)
        XCTAssertEqual(states, [], "keepOnPen must not journal a cleanup request")
    }

    func testADeletionPolicyStillNeverRequestsDeletion() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let importer = makeImporter(
            library: library,
            policy: PenCleanupPolicy(mode: .deleteAfterAcknowledge)
        )

        let outcome = try await importer.importRead(transfer([stroke(offset: 0)]), export: request())
        let save = try XCTUnwrap(outcome.save)

        // The request is prepared for the future hardware-gated flow, and stops
        // there: deletion stays disabled, so `requested` is never recorded.
        let states = try await library.recordedStates(batchID: save.batchID)
        XCTAssertEqual(states, [.prepared])
        XCTAssertFalse(PenCleanupPolicy(mode: .deleteAfterAcknowledge).deletionEnabled)
    }
}
