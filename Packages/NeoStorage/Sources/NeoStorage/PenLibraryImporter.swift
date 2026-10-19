import Foundation
import NeoCore

/// The portable verified importer: it turns one completed read into a durable
/// batch and, when asked, into published page files.
///
/// The lifecycle is two-phase and durable:
///
/// 1. `collect` records the read's strokes in memory and its page set durably.
/// 2. `validate` marks the batch ready, and `commit` stores every stroke in one
///    transaction.
/// 3. `publish` renders the committed rows, never the in-memory buffer, so a
///    retry after a failure re-reads exactly what was stored.
///
/// Pen cleanup stays disabled. The journal is written only when a policy asks for
/// deletion, which ``PenCleanupPolicy/deletionEnabled`` never allows in this
/// change, so no batch records a deletion request.
public actor PenLibraryImporter: PenImportCoordinator {
    private let store: any PenStrokeStore
    private let batches: any PenImportBatchStore
    private let journal: any PenCleanupJournal
    private let publisher: any PenExportPublisher
    private let policy: PenCleanupPolicy

    /// The strokes of batches that have been collected but not committed.
    ///
    /// The buffer is deliberately in memory: a process that restarts between
    /// collection and commit must read the pen again rather than commit a partial
    /// transfer.
    private var collected: [UUID: [Stroke]] = [:]

    /// What each committed batch added.
    private var insertions: [UUID: PenStrokeInsertion] = [:]

    /// Creates an importer.
    ///
    /// - Parameters:
    ///   - store: The stroke store, which must commit one call atomically.
    ///   - batches: The durable batch records.
    ///   - journal: The pen cleanup journal.
    ///   - publisher: The export publisher. It is only used when a caller asks
    ///     for publication.
    ///   - policy: The pen cleanup policy. It defaults to `keepOnPen`.
    public init(
        store: any PenStrokeStore,
        batches: any PenImportBatchStore,
        journal: any PenCleanupJournal,
        publisher: any PenExportPublisher,
        policy: PenCleanupPolicy = PenCleanupPolicy()
    ) {
        self.store = store
        self.batches = batches
        self.journal = journal
        self.publisher = publisher
        self.policy = policy
    }

    // MARK: - PenImportCoordinator

    public func collect(_ strokes: [Stroke]) async throws -> ImportBatch {
        let batch = ImportBatch()
        collected[batch.id] = strokes
        try await batches.save(record(for: batch.id, state: .collecting, strokes: strokes))
        return batch
    }

    public func validate(_ batchID: UUID) async throws {
        try await transition(batchID, to: .validated)
    }

    public func commit(_ batchID: UUID) async throws {
        guard let strokes = collected[batchID] else {
            throw StorageError.collectedStrokesUnavailable(batchID: batchID)
        }

        // The read's full point data is only needed until the insert resolves, so
        // the buffer is released whatever the insert does. A long-lived app would
        // otherwise keep every read for its whole lifetime.
        defer { collected[batchID] = nil }

        do {
            insertions[batchID] = try await store.insert(strokes)
        } catch {
            // The store rolled its transaction back, so the batch must not claim
            // to be committed.
            try? await transition(batchID, to: .failed)
            throw error
        }

        // The marker is written only once the strokes are durable, so a batch
        // recorded as committed always has its strokes. A crash between the two
        // leaves the batch validated, which a restart re-reads; the reverse order
        // could record a committed batch with no strokes.
        try await transition(batchID, to: .committed)
    }

    public func publish(_ batchID: UUID, request: PenExportRequest) async throws -> PenExportReport {
        let record = try await retryableBatch(batchID)
        let pages = request.pages.isEmpty ? record.pages : request.pages
        let content = try await content(for: pages)
        let report = await publisher.publish(
            PenExportRequest(
                formats: request.formats,
                pages: pages,
                destinationDirectory: request.destinationDirectory
            ),
            content: content
        )

        // Only a complete publication advances the batch. A partial one leaves it
        // committed, so the caller can retry without re-importing.
        if report.succeeded {
            try await transition(batchID, to: .published)
        }
        return report
    }

    public func acknowledge(_ batchID: UUID) async throws {
        guard let record = try await batches.batch(id: batchID), record.state == .published else {
            let existing = try await batches.batch(id: batchID)
            throw StorageError.batchNotReady(batchID: batchID, state: existing?.state)
        }

        // A deletion policy would record the request here. Deletion stays
        // disabled, so the journal is only written when a policy asks for it and
        // nothing is ever sent to the pen.
        if policy.mode == .deleteAfterAcknowledge {
            try await journal.record(.prepared, batchID: batchID)
        }
    }

    public func importRead(
        _ transfer: PenReadTransfer,
        export: PenExportRequest?,
        reporting: (@Sendable (PenImportStage) -> Void)?
    ) async throws -> PenImportOutcome {
        guard !transfer.isEmpty else {
            // A complete read with no stroke is a result, not a failure: it
            // stores nothing and publishes nothing.
            return .noStrokesFound
        }

        reporting?(.saving)
        let batch = try await collect(transfer.strokes)
        try await validate(batch.id)
        try await commit(batch.id)

        // The insertion counts are only needed for the save result, so the entry
        // is released once it has been read.
        let insertion = insertions.removeValue(forKey: batch.id)
            ?? PenStrokeInsertion(addedStrokeCount: 0, duplicateStrokeCount: 0)
        let save = PenLibrarySave(
            batchID: batch.id,
            pages: transfer.pages,
            insertion: insertion,
            strokeCount: transfer.strokeCount,
            dotCount: transfer.dotCount
        )

        guard let export else {
            return .saved(save, export: nil)
        }

        reporting?(.exporting)
        let report = try await publish(batch.id, request: export)
        if report.succeeded {
            try await acknowledge(batch.id)
        }
        return .saved(save, export: report)
    }

    public func retryExport(batchID: UUID, request: PenExportRequest) async throws -> PenExportReport {
        _ = try await retryableBatch(batchID)
        let report = try await publish(batchID, request: request)
        if report.succeeded {
            try await acknowledge(batchID)
        }
        return report
    }

    // MARK: - Helpers

    /// Returns a batch that can still publish, or explains why it cannot.
    private func retryableBatch(_ batchID: UUID) async throws -> PenImportBatchRecord {
        guard let record = try await batches.batch(id: batchID) else {
            throw StorageError.batchNotReady(batchID: batchID, state: nil)
        }
        guard record.isPublicationRetryable else {
            throw StorageError.batchNotReady(batchID: batchID, state: record.state)
        }
        return record
    }

    /// Renders every requested page that has stored strokes.
    private func content(for pages: [PageIdentity]) async throws -> [PenPageContent] {
        var content: [PenPageContent] = []
        for page in pages.sorted(by: PageIdentity.canonicalOrder) {
            let strokes = try await store.strokes(on: page)
            guard !strokes.isEmpty else { continue }
            content.append(PenPageContent(page: page, strokes: strokes))
        }
        return content
    }

    /// Moves a batch to another state, refusing an illegal move.
    private func transition(_ batchID: UUID, to next: ImportBatchState) async throws {
        guard let existing = try await batches.batch(id: batchID) else {
            throw StorageError.batchNotReady(batchID: batchID, state: nil)
        }

        var batch = ImportBatch(id: existing.batchID, state: existing.state)
        try batch.transition(to: next)

        try await batches.save(
            PenImportBatchRecord(
                batchID: existing.batchID,
                state: batch.state,
                pages: existing.pages,
                strokeCount: existing.strokeCount,
                dotCount: existing.dotCount
            )
        )
    }

    /// Builds a batch record for a collected read.
    private func record(
        for batchID: UUID,
        state: ImportBatchState,
        strokes: [Stroke]
    ) -> PenImportBatchRecord {
        var seen = Set<PageIdentity>()
        let pages = strokes
            .map(\.page)
            .filter { seen.insert($0).inserted }
            .sorted(by: PageIdentity.canonicalOrder)

        return PenImportBatchRecord(
            batchID: batchID,
            state: state,
            pages: pages,
            strokeCount: strokes.count,
            dotCount: strokes.reduce(0) { $0 + $1.points.count }
        )
    }
}
