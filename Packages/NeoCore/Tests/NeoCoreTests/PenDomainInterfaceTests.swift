import XCTest

@testable import NeoCore

/// An in-memory stroke store. It exists to prove the portable boundaries can be
/// exercised without platform imports.
private actor FakeStrokeStore: PenStrokeStore {
    private var storage: [PageIdentity: [Stroke]] = [:]
    private var reliableFingerprints: [String] = []
    private(set) var insertedFingerprints: [String] = []

    func insert(_ strokes: [Stroke]) async throws -> PenStrokeInsertion {
        var added = 0
        var duplicates = 0

        for stroke in strokes {
            let fingerprint = StrokeIdentity.fingerprint(of: stroke)
            if fingerprint.allowsCrossSourceDeduplication {
                guard !reliableFingerprints.contains(fingerprint.hexDigest) else {
                    duplicates += 1
                    continue
                }
                reliableFingerprints.append(fingerprint.hexDigest)
            }
            insertedFingerprints.append(fingerprint.hexDigest)
            storage[stroke.page, default: []].append(stroke)
            added += 1
        }

        return PenStrokeInsertion(addedStrokeCount: added, duplicateStrokeCount: duplicates)
    }

    func strokes(on page: PageIdentity) async throws -> [Stroke] {
        storage[page] ?? []
    }

    func pages() async throws -> [PageIdentity] {
        storage.keys.sorted(by: PageIdentity.canonicalOrder)
    }
}

/// A batch store that keeps records in memory.
private actor FakeBatchStore: PenImportBatchStore {
    private var records: [UUID: PenImportBatchRecord] = [:]
    private var order: [UUID] = []

    func save(_ record: PenImportBatchRecord) async throws {
        if records[record.batchID] == nil {
            order.append(record.batchID)
        }
        records[record.batchID] = record
    }

    func batch(id: UUID) async throws -> PenImportBatchRecord? {
        records[id]
    }

    func batches(in state: ImportBatchState) async throws -> [PenImportBatchRecord] {
        order.compactMap { records[$0] }.filter { $0.state == state }
    }
}

/// A publisher whose outcome a test scripts per format.
///
/// A scripted failure applies to the first publication only, so a test can show
/// that a retry completes the set.
private struct ScriptedExportPublisher: PenExportPublisher {
    /// The formats that fail on the first publication, and why.
    let failures: [PenExportFormat: String]

    /// How many publications have run.
    private let attempts = PublicationAttempts()

    func publish(_ request: PenExportRequest, content: [PenPageContent]) async -> PenExportReport {
        let isFirstAttempt = await attempts.begin()
        return PenExportReport(
            artifacts: request.formats.map { format in
                let reason = isFirstAttempt ? failures[format] : nil
                return PenExportArtifact(
                    format: format,
                    path: "\(request.destinationDirectory)/export.\(format.rawValue)",
                    byteCount: content.reduce(0) { $0 + $1.dotCount },
                    status: reason.map { .failed(reason: $0) } ?? .published
                )
            }
        )
    }
}

/// Counts publications so a scripted failure can be limited to the first one.
private actor PublicationAttempts {
    private var count = 0

    /// Records one publication.
    ///
    /// - Returns: Whether this is the first publication.
    func begin() -> Bool {
        count += 1
        return count == 1
    }
}

private actor FakeCleanupJournal: PenCleanupJournal {
    private var states: [UUID: [PenCleanupState]] = [:]

    func record(_ state: PenCleanupState, batchID: UUID) async throws {
        states[batchID, default: []].append(state)
    }

    func latestState(batchID: UUID) async throws -> PenCleanupState? {
        states[batchID]?.last
    }

    func recordedStates(batchID: UUID) async throws -> [PenCleanupState] {
        states[batchID] ?? []
    }
}

/// A portable stand-in for the durable library the storage package implements.
private struct FakeImportCoordinator: PenImportCoordinator {
    let store: FakeStrokeStore
    let batches: FakeBatchStore
    let journal: FakeCleanupJournal
    let publisher: any PenExportPublisher

    private let scratch = BatchScratch()

    func collect(_ strokes: [Stroke]) async throws -> ImportBatch {
        let batch = ImportBatch()
        await scratch.set(strokes, batchID: batch.id)
        try await batches.save(
            PenImportBatchRecord(
                batchID: batch.id,
                state: batch.state,
                pages: pages(of: strokes),
                strokeCount: strokes.count,
                dotCount: strokes.reduce(0) { $0 + $1.points.count }
            )
        )
        return batch
    }

    func validate(_ batchID: UUID) async throws {
        try await transition(batchID, to: .validated)
    }

    func commit(_ batchID: UUID) async throws {
        try await transition(batchID, to: .committed)
        let insertion = try await store.insert(await scratch.strokes(batchID))
        await scratch.setInsertion(insertion, batchID: batchID)
    }

    func publish(_ batchID: UUID, request: PenExportRequest) async throws -> PenExportReport {
        guard let record = try await batches.batch(id: batchID),
            record.state == .committed || record.state == .published
        else {
            throw ImportBatchTransitionError.illegalTransition(from: .collecting, to: .published)
        }

        let content = try await content(for: request.pages)
        let report = await publisher.publish(request, content: content)
        if report.succeeded {
            try await transition(batchID, to: .published)
        }
        return report
    }

    func acknowledge(_ batchID: UUID) async throws {
        guard let record = try await batches.batch(id: batchID), record.state == .published else {
            throw ImportBatchTransitionError.illegalTransition(from: .committed, to: .published)
        }
    }

    func importRead(
        _ transfer: PenReadTransfer,
        export: PenExportRequest?,
        reporting: (@Sendable (PenImportStage) -> Void)?
    ) async throws -> PenImportOutcome {
        guard !transfer.isEmpty else { return .noStrokesFound }

        reporting?(.saving)
        let batch = try await collect(transfer.strokes)
        try await validate(batch.id)
        try await commit(batch.id)

        let save = PenLibrarySave(
            batchID: batch.id,
            pages: transfer.pages,
            insertion: try await scratch.insertion(batch.id),
            strokeCount: transfer.strokeCount,
            dotCount: transfer.dotCount
        )

        guard let export else {
            return .saved(save, export: nil)
        }
        reporting?(.exporting)
        let report = try await publish(batch.id, request: export)
        return .saved(save, export: report)
    }

    func retryExport(batchID: UUID, request: PenExportRequest) async throws -> PenExportReport {
        guard let record = try await batches.batch(id: batchID), record.isPublicationRetryable else {
            throw ImportBatchTransitionError.illegalTransition(from: .collecting, to: .published)
        }
        return try await publish(batchID, request: request)
    }

    private func content(for pages: [PageIdentity]) async throws -> [PenPageContent] {
        var content: [PenPageContent] = []
        for page in pages.sorted(by: PageIdentity.canonicalOrder) {
            let strokes = try await store.strokes(on: page)
            guard !strokes.isEmpty else { continue }
            content.append(PenPageContent(page: page, strokes: strokes))
        }
        return content
    }

    private func pages(of strokes: [Stroke]) -> [PageIdentity] {
        var seen = Set<PageIdentity>()
        return strokes
            .map(\.page)
            .filter { seen.insert($0).inserted }
            .sorted(by: PageIdentity.canonicalOrder)
    }

    private func transition(_ batchID: UUID, to next: ImportBatchState) async throws {
        guard let record = try await batches.batch(id: batchID) else {
            throw ImportBatchTransitionError.illegalTransition(from: .collecting, to: next)
        }
        var batch = ImportBatch(id: record.batchID, state: record.state)
        try batch.transition(to: next)
        try await batches.save(
            PenImportBatchRecord(
                batchID: record.batchID,
                state: batch.state,
                pages: record.pages,
                strokeCount: record.strokeCount,
                dotCount: record.dotCount
            )
        )
    }
}

/// The strokes a batch collected, and what its commit stored, held outside the
/// coordinator's value type.
private actor BatchScratch {
    private var strokes: [UUID: [Stroke]] = [:]
    private var insertions: [UUID: PenStrokeInsertion] = [:]

    func set(_ strokes: [Stroke], batchID: UUID) {
        self.strokes[batchID] = strokes
    }

    func strokes(_ batchID: UUID) -> [Stroke] {
        strokes[batchID] ?? []
    }

    func setInsertion(_ insertion: PenStrokeInsertion, batchID: UUID) {
        insertions[batchID] = insertion
    }

    func insertion(_ batchID: UUID) throws -> PenStrokeInsertion {
        guard let insertion = insertions[batchID] else {
            throw ImportBatchTransitionError.illegalTransition(from: .collecting, to: .committed)
        }
        return insertion
    }
}

final class PenDomainInterfaceTests: XCTestCase {
    private let page = PageIdentity(section: 1, owner: 0x0000AB, book: 9, page: 2)

    private func stroke(offset: Int64, page: PageIdentity? = nil) -> Stroke {
        Stroke(
            page: page ?? self.page,
            originTime: .reliable(milliseconds: 1_700_000_000_000),
            points: [PenPoint(x: Int32(offset), y: 0, penTimeOffsetMilliseconds: offset, pressure: 10)],
            source: .offline
        )
    }

    private func unreliableStroke(page: PageIdentity? = nil) -> Stroke {
        Stroke(
            page: page ?? self.page,
            originTime: .unreliable(reportedMilliseconds: nil),
            points: [PenPoint(x: 1, y: 2, penTimeOffsetMilliseconds: 0, pressure: 1)],
            source: .offline
        )
    }

    private func makeCoordinator(
        failures: [PenExportFormat: String] = [:]
    ) -> (FakeImportCoordinator, FakeStrokeStore, FakeBatchStore, FakeCleanupJournal) {
        let store = FakeStrokeStore()
        let batches = FakeBatchStore()
        let journal = FakeCleanupJournal()
        let coordinator = FakeImportCoordinator(
            store: store,
            batches: batches,
            journal: journal,
            publisher: ScriptedExportPublisher(failures: failures)
        )
        return (coordinator, store, batches, journal)
    }

    private func request(pages: [PageIdentity]? = nil) -> PenExportRequest {
        PenExportRequest(
            pages: pages ?? [page],
            destinationDirectory: "/tmp/exports"
        )
    }

    // MARK: - Batch state machine

    func testImportBatchStateMachine() throws {
        var batch = ImportBatch()
        XCTAssertEqual(batch.state, .collecting)
        try batch.transition(to: .validated)
        try batch.transition(to: .committed)
        try batch.transition(to: .published)
        XCTAssertEqual(batch.state, .published)
    }

    func testIllegalImportTransitionIsRejected() {
        var batch = ImportBatch()
        XCTAssertThrowsError(try batch.transition(to: .published)) { error in
            XCTAssertEqual(
                error as? ImportBatchTransitionError,
                .illegalTransition(from: .collecting, to: .published)
            )
        }
        XCTAssertEqual(batch.state, .collecting)
    }

    func testFailedStateIsTerminal() throws {
        var batch = ImportBatch()
        try batch.transition(to: .failed)
        XCTAssertThrowsError(try batch.transition(to: .validated))
        XCTAssertEqual(batch.state, .failed)
    }

    // MARK: - Complete transfer data

    func testReadTransferKeepsCompleteTransferData() {
        let other = PageIdentity(section: 1, owner: 0x0000AB, book: 9, page: 3)
        let transfer = PenReadTransfer(
            strokes: [stroke(offset: 1, page: other), stroke(offset: 2), stroke(offset: 3)],
            noteCount: 2
        )

        XCTAssertEqual(transfer.strokeCount, 3)
        XCTAssertEqual(transfer.dotCount, 3)
        XCTAssertEqual(transfer.noteCount, 2)
        XCTAssertFalse(transfer.isEmpty)
        XCTAssertEqual(transfer.pages, [page, other], "pages must be distinct and in canonical order")
    }

    func testEmptyReadTransferReportsNoStrokes() {
        let transfer = PenReadTransfer(strokes: [], noteCount: 0)
        XCTAssertTrue(transfer.isEmpty)
        XCTAssertEqual(transfer.pages, [])
    }

    // MARK: - Store deduplication

    func testStoreDeduplicatesReplayedReliableStroke() async throws {
        let store = FakeStrokeStore()
        let stroke = stroke(offset: 0)

        let first = try await store.insert([stroke])
        let second = try await store.insert([stroke])

        XCTAssertEqual(first, PenStrokeInsertion(addedStrokeCount: 1, duplicateStrokeCount: 0))
        XCTAssertEqual(second, PenStrokeInsertion(addedStrokeCount: 0, duplicateStrokeCount: 1))

        let stored = try await store.strokes(on: page)
        XCTAssertEqual(stored.count, 1)
        let insertedCount = await store.insertedFingerprints.count
        XCTAssertEqual(insertedCount, 1)
    }

    func testStoreKeepsUnreliableOriginStrokesSeparate() async throws {
        let store = FakeStrokeStore()
        let unreliable = unreliableStroke()

        let first = try await store.insert([unreliable])
        let second = try await store.insert([unreliable])

        XCTAssertEqual(first.addedStrokeCount, 1)
        XCTAssertEqual(second.addedStrokeCount, 1, "an unreliable stroke must never collapse on a digest")
        XCTAssertEqual(second.duplicateStrokeCount, 0)

        let stored = try await store.strokes(on: page)
        XCTAssertEqual(stored.count, 2)
        XCTAssertFalse(StrokeIdentity.fingerprint(of: unreliable).allowsCrossSourceDeduplication)
    }

    func testStoreListsPagesInCanonicalOrder() async throws {
        let store = FakeStrokeStore()
        let early = PageIdentity(section: 1, owner: 1, book: 1, page: 1)
        let late = PageIdentity(section: 3, owner: 0, book: 0, page: 0)

        _ = try await store.insert([stroke(offset: 0, page: late), stroke(offset: 0, page: early)])

        let pages = try await store.pages()
        XCTAssertEqual(pages, [early, late])
    }

    // MARK: - Verified import

    func testImportReadSavesAndReportsExportedFiles() async throws {
        let (coordinator, store, batches, _) = makeCoordinator()

        let outcome = try await coordinator.importRead(
            PenReadTransfer(strokes: [stroke(offset: 0), stroke(offset: 5)], noteCount: 1),
            export: request()
        )

        let save = try XCTUnwrap(outcome.save)
        XCTAssertEqual(save.strokeCount, 2)
        XCTAssertEqual(save.insertion.addedStrokeCount, 2)
        XCTAssertEqual(save.pages, [page])
        XCTAssertEqual(outcome.export?.artifacts.map(\.format), [.json, .svg, .markdown])
        XCTAssertEqual(outcome.export?.succeeded, true)

        let stored = try await store.strokes(on: page)
        XCTAssertEqual(stored.count, 2)
        let record = try await batches.batch(id: save.batchID)
        XCTAssertEqual(record?.state, .published)
        XCTAssertEqual(record?.isPublicationRetryable, true)
    }

    func testImportReadReportsStorageSuccessWhenExportFails() async throws {
        let (coordinator, store, batches, _) = makeCoordinator(failures: [.svg: "disk full"])

        let outcome = try await coordinator.importRead(
            PenReadTransfer(strokes: [stroke(offset: 0)], noteCount: 1),
            export: request()
        )

        XCTAssertTrue(outcome.isSaved, "a publication failure must not unsave the read")
        let export = try XCTUnwrap(outcome.export)
        XCTAssertFalse(export.succeeded)
        XCTAssertEqual(export.failed.map(\.format), [.svg])
        XCTAssertEqual(export.failureMessages, ["disk full"])
        XCTAssertEqual(export.published.map(\.format), [.json, .markdown])

        let stored = try await store.strokes(on: page)
        XCTAssertEqual(stored.count, 1, "the committed strokes stay in the library")

        let save = try XCTUnwrap(outcome.save)
        let record = try await batches.batch(id: save.batchID)
        XCTAssertEqual(record?.state, .committed, "a failed publication leaves the batch retryable")
    }

    func testRetryExportCompletesAllThreeTargetsWithoutDuplicatingStrokes() async throws {
        let (coordinator, store, _, _) = makeCoordinator(failures: [.markdown: "locked"])

        let outcome = try await coordinator.importRead(
            PenReadTransfer(strokes: [stroke(offset: 0)], noteCount: 1),
            export: request()
        )
        let save = try XCTUnwrap(outcome.save)
        XCTAssertEqual(outcome.export?.failed.count, 1)

        let retry = try await coordinator.retryExport(batchID: save.batchID, request: request())
        XCTAssertTrue(retry.succeeded)
        XCTAssertEqual(retry.artifacts.count, 3)

        let stored = try await store.strokes(on: page)
        XCTAssertEqual(stored.count, 1, "a retry must not import the read again")
    }

    func testRetryExportRefusesAnUnknownBatch() async throws {
        let (coordinator, _, _, _) = makeCoordinator()
        do {
            _ = try await coordinator.retryExport(batchID: UUID(), request: request())
            XCTFail("expected an unknown batch to be refused")
        } catch {
            XCTAssertTrue(error is ImportBatchTransitionError)
        }
    }

    func testImportReadWithNoStrokesStoresNothingAndExportsNothing() async throws {
        let (coordinator, store, batches, _) = makeCoordinator()

        let outcome = try await coordinator.importRead(
            PenReadTransfer(strokes: [], noteCount: 0),
            export: request()
        )

        XCTAssertEqual(outcome, .noStrokesFound)
        XCTAssertNil(outcome.save)
        XCTAssertNil(outcome.export)
        let pages = try await store.pages()
        XCTAssertEqual(pages, [])
        let committed = try await batches.batches(in: .committed)
        XCTAssertEqual(committed, [])
    }

    func testImportReadWithoutAnExportRequestStaysCommittedAndRetryable() async throws {
        let (coordinator, _, _, _) = makeCoordinator()

        let outcome = try await coordinator.importRead(
            PenReadTransfer(strokes: [stroke(offset: 0)], noteCount: 1),
            export: nil
        )

        XCTAssertTrue(outcome.isSaved)
        XCTAssertNil(outcome.export)
        let save = try XCTUnwrap(outcome.save)

        let retry = try await coordinator.retryExport(batchID: save.batchID, request: request())
        XCTAssertTrue(retry.succeeded, "a stored read can be exported later")
    }

    func testUnvalidatedBatchCannotCommit() async throws {
        let (coordinator, store, _, _) = makeCoordinator()
        let batch = try await coordinator.collect([stroke(offset: 0)])

        do {
            try await coordinator.commit(batch.id)
            XCTFail("expected a commit before validation to be refused")
        } catch {
            XCTAssertTrue(error is ImportBatchTransitionError)
        }

        let stored = try await store.strokes(on: page)
        XCTAssertEqual(stored, [], "a refused commit must store nothing")
    }

    // MARK: - Cleanup journal and retention

    func testCleanupJournalRecordsDurableStates() async throws {
        let journal = FakeCleanupJournal()
        let batchID = UUID()

        try await journal.record(.prepared, batchID: batchID)
        let prepared = try await journal.latestState(batchID: batchID)
        XCTAssertEqual(prepared, .prepared)
        try await journal.record(.requested, batchID: batchID)
        try await journal.record(.confirmed, batchID: batchID)
        let confirmed = try await journal.latestState(batchID: batchID)
        XCTAssertEqual(confirmed, .confirmed)
        let all = try await journal.recordedStates(batchID: batchID)
        XCTAssertEqual(all, [.prepared, .requested, .confirmed])
    }

    func testCleanupDefaultsToKeepOnPenAndDeletionIsDisabled() {
        let policy = PenCleanupPolicy()
        XCTAssertEqual(policy.mode, .keepOnPen)
        XCTAssertFalse(policy.deletionEnabled)

        let explicit = PenCleanupPolicy(mode: .deleteAfterAcknowledge)
        XCTAssertFalse(explicit.deletionEnabled)
    }

    // MARK: - Export report

    func testExportReportCountsUnchangedTargetsAsSuccess() {
        let report = PenExportReport(artifacts: [
            PenExportArtifact(
                format: .json,
                path: "/tmp/page.json",
                byteCount: 10,
                status: .unchanged
            ),
            PenExportArtifact(
                format: .svg,
                path: "/tmp/page.svg",
                byteCount: 20,
                status: .published
            ),
        ])

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.unchanged.map(\.format), [.json])
        XCTAssertEqual(report.published.map(\.format), [.svg])
        XCTAssertEqual(report.failed, [])
        XCTAssertEqual(report.failureMessages, [])
    }

    func testExportReportNamesEveryFailedTarget() {
        let report = PenExportReport(artifacts: [
            PenExportArtifact(
                format: .json,
                path: "/tmp/page.json",
                byteCount: 10,
                status: .failed(reason: "the destination directory is missing")
            ),
            PenExportArtifact(
                format: .svg,
                path: "/tmp/page.svg",
                byteCount: 20,
                status: .failed(reason: "the target is a symlink")
            ),
        ])

        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(
            report.failureMessages,
            ["the destination directory is missing", "the target is a symlink"]
        )
        XCTAssertEqual(report.failed.count, 2)
        XCTAssertEqual(report.published, [])
    }

    // MARK: - Batch records

    func testBatchRecordIsRetryableOnlyAfterCommit() {
        let batchID = UUID()
        func record(_ state: ImportBatchState) -> PenImportBatchRecord {
            PenImportBatchRecord(
                batchID: batchID,
                state: state,
                pages: [page],
                strokeCount: 1,
                dotCount: 3
            )
        }

        XCTAssertFalse(record(.collecting).isPublicationRetryable)
        XCTAssertFalse(record(.validated).isPublicationRetryable)
        XCTAssertTrue(record(.committed).isPublicationRetryable)
        XCTAssertTrue(record(.published).isPublicationRetryable)
        XCTAssertFalse(record(.failed).isPublicationRetryable)
    }
}
