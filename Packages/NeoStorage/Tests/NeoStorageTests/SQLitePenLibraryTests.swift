import Foundation
import NeoCore
import XCTest

@testable import NeoStorage

/// Tests for the portable SQLite library: schema, round trips, deduplication,
/// atomic batches, batch progress, and the cleanup journal.
final class SQLitePenLibraryTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory.remove()
        directory = nil
    }

    // MARK: - Helpers

    private func stroke(
        page: PageIdentity,
        offset: Int64 = 0,
        origin: PenOriginTime = .reliable(milliseconds: 1_700_000_000_000),
        source: PenSource = .offline,
        points: [PenPoint]? = nil
    ) -> Stroke {
        Stroke(
            page: page,
            originTime: origin,
            points: points ?? [
                PenPoint(
                    x: Int32(offset),
                    y: Int32(-offset),
                    penTimeOffsetMilliseconds: offset,
                    pressure: 12
                )
            ],
            source: source
        )
    }

    private let page = PageIdentity(section: 3, owner: 27, book: 700, page: 1)

    // MARK: - Round trips

    func testStrokesAndPointsSurviveAReopen() async throws {
        let url = directory.file("library.sqlite")
        let origin = PenOriginTime.reliable(milliseconds: 1_700_000_000_123)
        let points = [
            PenPoint(x: -12_345, y: 67_890, penTimeOffsetMilliseconds: -7, pressure: 0),
            PenPoint(x: 1, y: 2, penTimeOffsetMilliseconds: 4_000_000_000, pressure: 65_535),
        ]

        do {
            let library = try SQLitePenLibrary(url: url)
            _ = try await library.insert([stroke(page: page, origin: origin, points: points)])
        }

        let reopened = try SQLitePenLibrary(url: url)
        let stored = try await reopened.strokes(on: page)

        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.originTime, origin)
        XCTAssertEqual(stored.first?.points, points)
        XCTAssertEqual(stored.first?.source, .offline)
        XCTAssertEqual(stored.first?.page, page)
    }

    func testUnreliableOriginWithNoReportedTimeSurvivesAReopen() async throws {
        let url = directory.file("library.sqlite")
        let origin = PenOriginTime.unreliable(reportedMilliseconds: nil)

        do {
            let library = try SQLitePenLibrary(url: url)
            _ = try await library.insert([stroke(page: page, origin: origin)])
        }

        let reopened = try SQLitePenLibrary(url: url)
        let stored = try await reopened.strokes(on: page)
        XCTAssertEqual(stored.first?.originTime, origin)
    }

    func testSamePageNumberInDifferentBooksStaysDistinctAfterAReopen() async throws {
        let url = directory.file("library.sqlite")
        let otherBook = PageIdentity(section: 3, owner: 27, book: 701, page: 1)
        let otherOwner = PageIdentity(section: 3, owner: 28, book: 700, page: 1)

        do {
            let library = try SQLitePenLibrary(url: url)
            _ = try await library.insert([
                stroke(page: page),
                stroke(page: otherBook),
                stroke(page: otherOwner),
            ])
        }

        let reopened = try SQLitePenLibrary(url: url)
        let pages = try await reopened.pages()

        XCTAssertEqual(pages, [page, otherOwner, otherBook].sorted(by: PageIdentity.canonicalOrder))
        for candidate in [page, otherBook, otherOwner] {
            let stored = try await reopened.strokes(on: candidate)
            XCTAssertEqual(stored.count, 1)
            XCTAssertEqual(stored.first?.page, candidate)
        }
    }

    func testPagesAreListedInCanonicalOrder() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let last = PageIdentity(section: 3, owner: 27, book: 700, page: 9)
        let first = PageIdentity(section: 1, owner: 0, book: 0, page: 0)

        _ = try await library.insert([stroke(page: last), stroke(page: first)])

        let pages = try await library.pages()
        XCTAssertEqual(pages, [first, last])
    }

    // MARK: - Deduplication

    func testReplayedReliableStrokeIsDeduplicated() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let stroke = stroke(page: page, source: .offline)

        let first = try await library.insert([stroke])
        let second = try await library.insert([stroke])

        XCTAssertEqual(first, PenStrokeInsertion(addedStrokeCount: 1, duplicateStrokeCount: 0))
        XCTAssertEqual(second, PenStrokeInsertion(addedStrokeCount: 0, duplicateStrokeCount: 1))

        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 1)
    }

    func testLiveAndOfflineCopiesOfTheSameStrokeDeduplicate() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))

        _ = try await library.insert([stroke(page: page, source: .live)])
        let second = try await library.insert([stroke(page: page, source: .offline)])

        XCTAssertEqual(second.addedStrokeCount, 0, "the source must not be part of stroke identity")
        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 1)
    }

    func testUnreliableStrokesKeepTheirMultiplicity() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let unreliable = stroke(page: page, origin: .unreliable(reportedMilliseconds: nil))

        let first = try await library.insert([unreliable])
        let second = try await library.insert([unreliable])
        let third = try await library.insert([unreliable])

        XCTAssertEqual(first.addedStrokeCount, 1)
        XCTAssertEqual(second.addedStrokeCount, 1)
        XCTAssertEqual(third.addedStrokeCount, 1)
        XCTAssertEqual(second.duplicateStrokeCount, 0)

        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 3, "an unreliable stroke must never collapse on a matching digest")
    }

    func testUnreliableAndReliableStrokesWithTheSameDigestBothSurvive() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let points = [PenPoint(x: 5, y: 5, penTimeOffsetMilliseconds: 0, pressure: 1)]

        // The two strokes differ only in reliability, which the canonical
        // encoding records, so they are different rows either way.
        _ = try await library.insert([
            stroke(page: page, origin: .reliable(milliseconds: 0), points: points)
        ])
        _ = try await library.insert([
            stroke(page: page, origin: .unreliable(reportedMilliseconds: nil), points: points)
        ])

        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.filter { $0.originTime.isReliable }.count, 1)
    }

    // MARK: - Atomicity

    func testAFailedImportRollsTheWholeBatchBack() async throws {
        let url = directory.file("library.sqlite")
        let library = try SQLitePenLibrary(
            url: url,
            faultInjection: { index in
                if index == 1 { throw InjectedFailure.stopped }
            }
        )

        let second = stroke(page: page, offset: 5)
        do {
            _ = try await library.insert([stroke(page: page, offset: 0), second])
            XCTFail("expected the injected failure to surface")
        } catch {
            XCTAssertEqual(error as? InjectedFailure, .stopped)
        }

        let stored = try await library.strokes(on: page)
        XCTAssertEqual(stored, [], "a partial batch must never be visible")

        // The library is still usable after the rollback.
        let reopened = try SQLitePenLibrary(url: url)
        let afterReopen = try await reopened.strokes(on: page)
        XCTAssertEqual(afterReopen, [])
        let insertion = try await reopened.insert([second])
        XCTAssertEqual(insertion.addedStrokeCount, 1)
    }

    // MARK: - Schema

    func testTheDatabaseRunsInWriteAheadLoggingMode() async throws {
        let url = directory.file("library.sqlite")
        _ = try SQLitePenLibrary(url: url)

        // The journal mode is recorded in the file, so a second connection sees
        // the mode the library chose.
        let connection = try SQLiteConnection(path: url.path)
        let statement = try connection.prepare("PRAGMA journal_mode")
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.text(0)?.lowercased(), "wal")
    }

    func testASchemaFromANewerBuildIsRefused() async throws {
        let url = directory.file("library.sqlite")
        _ = try SQLitePenLibrary(url: url)

        let connection = try SQLiteConnection(path: url.path)
        try connection.execute("UPDATE metadata SET value = '99' WHERE key = 'schema_version'")

        XCTAssertThrowsError(try SQLitePenLibrary(url: url)) { error in
            XCTAssertEqual(
                error as? StorageError,
                .unsupportedSchemaVersion(found: 99, supported: SQLitePenLibrary.schemaVersion)
            )
        }
    }

    func testAnExistingDatabaseIsReopenedWithoutRewritingItsSchemaVersion() async throws {
        let url = directory.file("library.sqlite")
        _ = try SQLitePenLibrary(url: url)
        _ = try SQLitePenLibrary(url: url)

        let connection = try SQLiteConnection(path: url.path)
        let statement = try connection.prepare(
            "SELECT value FROM metadata WHERE key = 'schema_version'"
        )
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(Int(statement.int64(0)), SQLitePenLibrary.schemaVersion)

        // Reopening must not append a second version row.
        let count = try connection.prepare("SELECT COUNT(*) FROM metadata")
        XCTAssertTrue(try count.step())
        XCTAssertEqual(Int(count.int64(0)), 1)
    }

    // MARK: - Batch progress

    func testBatchProgressSurvivesAReopen() async throws {
        let url = directory.file("library.sqlite")
        let batchID = UUID()

        do {
            let library = try SQLitePenLibrary(url: url)
            try await library.save(
                PenImportBatchRecord(
                    batchID: batchID,
                    state: .validated,
                    pages: [page],
                    strokeCount: 2,
                    dotCount: 6
                )
            )
        }

        let reopened = try SQLitePenLibrary(url: url)
        let record = try await reopened.batch(id: batchID)
        XCTAssertEqual(record?.state, .validated)
        XCTAssertEqual(record?.pages, [page])
        XCTAssertEqual(record?.strokeCount, 2)
        XCTAssertEqual(record?.dotCount, 6)
        XCTAssertEqual(record?.isPublicationRetryable, false)

        try await reopened.save(
            PenImportBatchRecord(
                batchID: batchID,
                state: .committed,
                pages: [page],
                strokeCount: 2,
                dotCount: 6
            )
        )
        let committed = try await reopened.batches(in: .committed)
        XCTAssertEqual(committed.map(\.batchID), [batchID])
        XCTAssertEqual(committed.first?.isPublicationRetryable, true)
    }

    func testBatchesAreListedOldestFirst() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let first = UUID()
        let second = UUID()

        for batchID in [first, second] {
            try await library.save(
                PenImportBatchRecord(
                    batchID: batchID,
                    state: .committed,
                    pages: [page],
                    strokeCount: 1,
                    dotCount: 1
                )
            )
        }

        let committed = try await library.batches(in: .committed)
        XCTAssertEqual(committed.map(\.batchID), [first, second])
    }

    // MARK: - Cleanup journal

    private func scope(
        batchID: UUID,
        target: PenDeletionTarget = .note,
        pages: [PageIdentity]? = nil
    ) -> PenDeletionScope {
        PenDeletionScope(batchID: batchID, target: target, pages: pages ?? [page])
    }

    func testCleanupJournalRecordsEveryStateAcrossAReopen() async throws {
        let url = directory.file("library.sqlite")
        let batchID = UUID()
        let scope = scope(batchID: batchID)

        do {
            let library = try SQLitePenLibrary(url: url)
            try await library.record(.prepared, scope: scope)
            try await library.record(.requested, scope: scope)
        }

        let reopened = try SQLitePenLibrary(url: url)
        let latest = try await reopened.latestState(batchID: batchID)
        XCTAssertEqual(latest, .requested)

        try await reopened.record(.confirmed, scope: scope)
        let states = try await reopened.recordedStates(batchID: batchID)
        XCTAssertEqual(states, [.prepared, .requested, .confirmed])
    }

    func testCleanupJournalHasNoStateForAnUnknownBatch() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let state = try await library.latestState(batchID: UUID())
        XCTAssertNil(state)
        let scope = try await library.recordedScope(batchID: UUID())
        XCTAssertNil(scope)
    }

    func testCleanupJournalReturnsTheRecordedScopeInCanonicalOrder() async throws {
        let url = directory.file("library.sqlite")
        let batchID = UUID()
        let later = PageIdentity(section: 3, owner: 27, book: 700, page: 9)
        let earlier = PageIdentity(section: 3, owner: 27, book: 700, page: 2)
        let recorded = scope(batchID: batchID, target: .page, pages: [later, earlier])

        do {
            let library = try SQLitePenLibrary(url: url)
            try await library.record(.prepared, scope: recorded)
        }

        let reopened = try SQLitePenLibrary(url: url)
        let stored = try await reopened.recordedScope(batchID: batchID)
        XCTAssertEqual(stored?.target, .page)
        XCTAssertEqual(stored?.pages, [earlier, later])
    }

    func testOutstandingScopesListOnlyRequestedBatchesOldestFirst() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let requestedFirst = UUID()
        let requestedSecond = UUID()
        let prepared = UUID()
        let confirmed = UUID()

        try await library.record(.requested, scope: scope(batchID: requestedFirst))
        try await library.record(.prepared, scope: scope(batchID: confirmed))
        try await library.record(.requested, scope: scope(batchID: confirmed))
        try await library.record(.confirmed, scope: scope(batchID: confirmed))
        try await library.record(.prepared, scope: scope(batchID: prepared))
        try await library.record(.requested, scope: scope(batchID: requestedSecond))

        let outstanding = try await library.outstandingScopes()
        XCTAssertEqual(outstanding.map(\.batchID), [requestedFirst, requestedSecond])
    }

    func testAConfirmedScopeIsNoLongerOutstanding() async throws {
        let library = try SQLitePenLibrary(url: directory.file("library.sqlite"))
        let batchID = UUID()
        let scope = scope(batchID: batchID)

        try await library.record(.requested, scope: scope)
        var outstanding = try await library.outstandingScopes()
        XCTAssertEqual(outstanding.map(\.batchID), [batchID])

        try await library.record(.confirmed, scope: scope)
        outstanding = try await library.outstandingScopes()
        XCTAssertTrue(outstanding.isEmpty)
    }

    func testAnUndecodableRecordedScopeIsRefused() async throws {
        let url = directory.file("library.sqlite")
        let batchID = UUID()

        do {
            let library = try SQLitePenLibrary(url: url)
            try await library.record(.prepared, scope: scope(batchID: batchID))
        }

        // A row this build cannot decode must be refused rather than read as an
        // empty scope: "the pen no longer holds these pages" is exactly the claim
        // a deletion outcome must not invent.
        do {
            let connection = try SQLiteConnection(path: url.path)
            try connection.execute("UPDATE cleanup_requests SET pages = 'not json'")
        }

        let reopened = try SQLitePenLibrary(url: url)
        do {
            _ = try await reopened.recordedScope(batchID: batchID)
            XCTFail("expected an undecodable scope to be refused")
        } catch {
            XCTAssertEqual(error as? StorageError, .unreadableCleanupScope(batchID: batchID))
        }
    }

    func testAnUndecodableJournalStateIsRefused() async throws {
        let url = directory.file("library.sqlite")
        let batchID = UUID()

        do {
            let library = try SQLitePenLibrary(url: url)
            try await library.record(.requested, scope: scope(batchID: batchID))
        }

        // A state this build cannot read must not be reported as "no request",
        // which is the one answer that would let the same deletion be sent twice.
        do {
            let connection = try SQLiteConnection(path: url.path)
            try connection.execute("UPDATE cleanup_journal SET state = 'unknown'")
        }

        let reopened = try SQLitePenLibrary(url: url)
        do {
            _ = try await reopened.latestState(batchID: batchID)
            XCTFail("expected an undecodable state to be refused")
        } catch {
            XCTAssertEqual(error as? StorageError, .unreadableCleanupState(batchID: batchID))
        }

        do {
            _ = try await reopened.recordedStates(batchID: batchID)
            XCTFail("expected the recorded history to refuse the same row")
        } catch {
            XCTAssertEqual(error as? StorageError, .unreadableCleanupState(batchID: batchID))
        }
    }
}
