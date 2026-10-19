import XCTest

@testable import NeoCore

/// An in-memory stroke store. It exists to prove the portable boundaries can be
/// exercised without platform imports.
private actor FakeStrokeStore: PenStrokeStore {
    private var storage: [PageIdentity: [Stroke]] = [:]
    private(set) var insertedFingerprints: [String] = []

    func insert(_ strokes: [Stroke]) async throws {
        for stroke in strokes {
            let fingerprint = StrokeIdentity.fingerprint(of: stroke)
            guard !insertedFingerprints.contains(fingerprint.hexDigest) else { continue }
            insertedFingerprints.append(fingerprint.hexDigest)
            storage[stroke.page, default: []].append(stroke)
        }
    }

    func strokes(on page: PageIdentity) async throws -> [Stroke] {
        storage[page] ?? []
    }
}

private struct FakeExportPublisher: PenExportPublisher {
    func publish(_ request: PenExportRequest, strokes: [Stroke]) async throws -> [PenExportArtifact] {
        request.formats.map {
            PenExportArtifact(
                format: $0,
                path: "\(request.destinationDirectory)/export.\($0.rawValue)",
                byteCount: strokes.count
            )
        }
    }
}

private actor FakeCleanupJournal: PenCleanupJournal {
    private var states: [UUID: PenCleanupState] = [:]

    func record(_ state: PenCleanupState, batchID: UUID) async throws {
        states[batchID] = state
    }

    func latestState(batchID: UUID) async throws -> PenCleanupState? {
        states[batchID]
    }
}

private struct FakeImportCoordinator: PenImportCoordinator {
    let store: FakeStrokeStore
    private let batches = BatchRegistry()

    func collect(_ strokes: [Stroke]) async throws -> ImportBatch {
        let batch = ImportBatch()
        await batches.set(batch, strokes: strokes)
        return batch
    }

    func validate(_ batchID: UUID) async throws {
        try await batches.transition(batchID, to: .validated)
    }

    func commit(_ batchID: UUID) async throws {
        try await batches.transition(batchID, to: .committed)
        try await store.insert(await batches.strokes(batchID))
    }

    func publish(_ batchID: UUID, request: PenExportRequest) async throws -> [PenExportArtifact] {
        try await batches.transition(batchID, to: .published)
        let strokes = await batches.strokes(batchID)
        return try await FakeExportPublisher().publish(request, strokes: strokes)
    }

    func acknowledge(_ batchID: UUID) async throws {
        _ = try await batches.state(batchID)
    }
}

private actor BatchRegistry {
    private var batches: [UUID: ImportBatch] = [:]
    private var strokes: [UUID: [Stroke]] = [:]

    func set(_ batch: ImportBatch, strokes: [Stroke]) {
        batches[batch.id] = batch
        self.strokes[batch.id] = strokes
    }

    func state(_ id: UUID) throws -> ImportBatchState {
        guard let batch = batches[id] else {
            throw ImportBatchTransitionError.illegalTransition(from: .collecting, to: .failed)
        }
        return batch.state
    }

    func transition(_ id: UUID, to next: ImportBatchState) throws {
        guard var batch = batches[id] else {
            throw ImportBatchTransitionError.illegalTransition(from: .collecting, to: next)
        }
        try batch.transition(to: next)
        batches[id] = batch
    }

    func strokes(_ id: UUID) -> [Stroke] {
        strokes[id] ?? []
    }
}

final class PenDomainInterfaceTests: XCTestCase {
    private let page = PageIdentity(section: 1, owner: 0x0000AB, book: 9, page: 2)

    private func stroke(offset: Int64) -> Stroke {
        Stroke(
            page: page,
            originTime: .reliable(milliseconds: 1_700_000_000_000),
            points: [PenPoint(x: Int32(offset), y: 0, penTimeOffsetMilliseconds: offset, pressure: 10)],
            source: .offline
        )
    }

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

    func testFakeStoreDeduplicatesReplayedStroke() async throws {
        let store = FakeStrokeStore()
        let stroke = stroke(offset: 0)

        try await store.insert([stroke])
        try await store.insert([stroke])

        let stored = try await store.strokes(on: page)
        XCTAssertEqual(stored.count, 1)
        let insertedCount = await store.insertedFingerprints.count
        XCTAssertEqual(insertedCount, 1)
    }

    func testFakeStoreKeepsUnreliableOriginStrokesSeparate() async throws {
        let store = FakeStrokeStore()
        let unreliable = Stroke(
            page: page,
            originTime: .unreliable(reportedMilliseconds: nil),
            points: [PenPoint(x: 1, y: 2, penTimeOffsetMilliseconds: 0, pressure: 1)],
            source: .offline
        )
        try await store.insert([unreliable])
        let stored = try await store.strokes(on: page)
        XCTAssertEqual(stored.count, 1)
        XCTAssertFalse(StrokeIdentity.fingerprint(of: unreliable).allowsCrossSourceDeduplication)
    }

    func testFakeImportCoordinatorRunsVerifiedImport() async throws {
        let store = FakeStrokeStore()
        let coordinator = FakeImportCoordinator(store: store)
        let batch = try await coordinator.collect([stroke(offset: 0), stroke(offset: 5)])

        try await coordinator.validate(batch.id)
        try await coordinator.commit(batch.id)

        let artifacts = try await coordinator.publish(
            batch.id,
            request: PenExportRequest(
                formats: [.json, .svg, .markdown],
                pages: [page],
                destinationDirectory: "/tmp/exports"
            )
        )
        XCTAssertEqual(artifacts.map(\.format), [.json, .svg, .markdown])
        let stored = try await store.strokes(on: page)
        XCTAssertEqual(stored.count, 2)
        try await coordinator.acknowledge(batch.id)
    }

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
    }

    func testCleanupDefaultsToKeepOnPenAndDeletionIsDisabled() {
        let policy = PenCleanupPolicy()
        XCTAssertEqual(policy.mode, .keepOnPen)
        XCTAssertFalse(policy.deletionEnabled)

        let explicit = PenCleanupPolicy(mode: .deleteAfterAcknowledge)
        XCTAssertFalse(explicit.deletionEnabled)
    }
}
