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
/// Cleanup is a fourth step, requested separately from the import so it can be
/// ordered after it. `requestCleanup` records the exact scope durably, marks it
/// requested before any byte can reach the pen, and marks it confirmed only when
/// the pen proves the recorded scope was removed. It refuses a batch that is not
/// published, so a read that failed to store, whose export did not publish in
/// full, or that requested no export at all never reaches the pen as a deletion.
/// It also refuses a scope that shares a page with a batch that has not published,
/// so a completed note is reclaimed only when its pages are its own. A cancelled
/// sync sends nothing, and one batch is never the subject of two concurrent
/// requests.
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

    /// The batches whose cleanup request is between its checks and its send.
    ///
    /// An actor suspends at every `await`, so two requests for one batch can both
    /// read the journal before either records into it. The set closes that window,
    /// because a deletion that has already been sent can never be taken back.
    private var cleanupsInFlight: Set<UUID> = []

    /// Creates an importer.
    ///
    /// - Parameters:
    ///   - store: The stroke store, which must commit one call atomically.
    ///   - batches: The durable batch records.
    ///   - journal: The pen cleanup journal.
    ///   - publisher: The export publisher. It is only used when a caller asks
    ///     for publication.
    ///   - policy: The pen cleanup policy. Its evidence gate decides whether a
    ///     deletion may be sent at all.
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
        // committed, so the caller can retry without re-importing. A batch that is
        // already published is republished for its files — its state is terminal,
        // so the move is skipped rather than attempted.
        if report.succeeded, record.state != .published {
            try await transition(batchID, to: .published)
        }
        return report
    }

    public func requestCleanup(
        _ batchID: UUID,
        request: PenCleanupRequest
    ) async throws -> PenCleanupOutcome {
        guard let record = try await batches.batch(id: batchID) else {
            throw StorageError.batchNotReady(batchID: batchID, state: nil)
        }

        // Retention is the outcome of the sync, not a skipped cleanup, so nothing
        // is recorded and nothing is sent.
        guard request.mode == .deleteAfterAcknowledge else {
            return .retainedByChoice
        }

        // A read that stored no page has nothing to reclaim, so no empty scope is
        // journaled and no empty deletion is ever sent.
        guard !record.pages.isEmpty else {
            return .skipped(reason: "the read stored no pages, so there is nothing to reclaim")
        }

        // The ordering rule: only a read whose complete transfer committed and
        // whose export published in full may have its pen copy reclaimed. A failed
        // or partial publication, and a read that requested no export at all, all
        // leave the batch committed, so they are refused here rather than after a
        // deletion: with nothing published, the library copy is the read's only
        // copy, and the pen's copy is what the user would fall back on.
        guard record.state == .published else {
            return .skipped(
                reason: "no export published in full for this read (batch state"
                    + " \(record.state.rawValue)), so the library copy is its only copy"
                    + " and the pen's copy is retained"
            )
        }

        // Completed notes can be reclaimed independently, but only when the scope
        // is theirs alone: a page that a sync which has not completed also touches
        // would lose that sync's strokes from the pen, so it is retained.
        let shared = try await pagesSharedWithAnIncompleteSync(
            record.pages,
            excluding: batchID
        )
        guard shared.isEmpty else {
            return .skipped(
                reason: "\(shared.count) page(s) in this read are also part of a sync that"
                    + " has not completed, so the pen's copy is retained"
            )
        }

        // A second request for the batch while the first is between its journal
        // read and its journal write would pass the same checks and send the
        // command twice, so the batch is marked in flight for the whole of this
        // call. The journal's terminal states cannot cover that window on their
        // own, because they are written inside it.
        guard !cleanupsInFlight.contains(batchID) else {
            return .outstanding(
                reason: "another cleanup request for this read is already in flight"
            )
        }
        cleanupsInFlight.insert(batchID)
        defer { cleanupsInFlight.remove(batchID) }

        // The journal is terminal in both directions: a request whose effect is
        // unknown is never repeated automatically, and one the pen already
        // confirmed is never sent a second time. A later sync resolves an
        // outstanding request by reading the pen and comparing, not by resending.
        let state: PenCleanupState?
        var recorded: PenDeletionScope?
        do {
            state = try await journal.latestState(batchID: batchID)
            if state == .confirmed {
                recorded = try await journal.recordedScope(batchID: batchID)
            }
        } catch let error as StorageError where error.isUnreadableCleanupRecord {
            // A row this build cannot read means the effect of an earlier request is
            // unknown, which is an outstanding request rather than one that never
            // ran, so it is reported as outstanding and never repeated.
            return .outstanding(reason: Self.unreadableJournalReason)
        }

        if state == .requested {
            return .outstanding(
                reason: "an earlier deletion request for this read has not been confirmed"
            )
        }
        if state == .confirmed {
            guard let recorded else {
                // The journal claims a reclamation it cannot substantiate, so the
                // removal is not proven and the request is not repeated.
                return .outstanding(
                    reason: "the journal records this read as reclaimed, but its"
                        + " recorded scope is missing"
                )
            }
            return .reclaimed(pageCount: recorded.pageCount)
        }

        // The gate is data, not a constant: it names the conditions no trace has
        // established yet.
        if let reason = policy.skipReason(for: request.mode) {
            return .skipped(reason: reason)
        }
        guard let target = policy.provenTarget else {
            return .skipped(reason: policy.evidence.blockingReason)
        }
        guard let sender = request.sender else {
            return .skipped(reason: "no pen link is available to send the deletion command")
        }

        // The exact scope is the batch's own committed pages, so a deletion can
        // only ever target data that was stored.
        let scope = PenDeletionScope(batchID: batchID, target: target, pages: record.pages)

        // A sync the user ended may have been cancelled while this call waited for
        // the journal, and a cancelled sync must reach the pen with nothing at all,
        // so the task is checked before anything is recorded.
        guard !Task.isCancelled else {
            return .outstanding(reason: Self.cancelledReason)
        }

        // Recorded before anything can be sent, then marked requested before the
        // bytes can reach the pen: a crash between the two leaves a scope that a
        // fresh read can be compared with.
        try await journal.record(.prepared, scope: scope)
        try await journal.record(.requested, scope: scope)

        // Cancelling during those two writes leaves the request recorded and
        // unsent. That is the same state a crash between them leaves, so the
        // request stays outstanding and a later read resolves it by comparing;
        // nothing is sent for the sync the user ended.
        guard !Task.isCancelled else {
            return .outstanding(reason: Self.cancelledReason)
        }

        // The request is already marked requested, so a send that fails leaves an
        // unknown effect rather than a known refusal.
        let deletion: PenDeletionOutcome
        do {
            deletion = try await sender.delete(scope)
        } catch {
            return .outstanding(
                reason: "the deletion command failed after it was recorded: \(error)"
            )
        }

        switch deletion {
        case .confirmed(let confirmed) where confirmed == scope:
            // The pen proved the removal, so the outcome is reclaimed whatever the
            // journal does next: reporting retention here would misstate what
            // happened to the user's only copy. A record that cannot be written
            // leaves the request `.requested`, which is the same state a crash
            // between the send and the write leaves, so a later read resolves it by
            // comparing rather than by resending.
            try? await journal.record(.confirmed, scope: scope)
            return .reclaimed(pageCount: scope.pageCount)

        case .confirmed:
            // A confirmation for a different scope proves nothing about this one.
            return .outstanding(reason: "the pen confirmed a different scope than the one recorded")

        case .unacknowledged:
            return .outstanding(
                reason: "the pen did not acknowledge the deletion command before its timeout"
            )

        case .refused(_, let code):
            return .outstanding(reason: "the pen refused the deletion command (error \(code))")
        }
    }

    /// The deletion requests whose effect is not yet known.
    public func outstandingCleanups() async throws -> [PenDeletionScope] {
        try await journal.outstandingScopes()
    }

    /// Resolves an outstanding request from the pen's whole stored-page inventory.
    ///
    /// The comparison is the only thing that may resolve a request, and it never
    /// deletes: a scope whose pages are all absent is confirmed, and a scope with any
    /// page still on the pen stays outstanding so it is not repeated blindly. Data
    /// the read did not expect is never touched.
    ///
    /// The request is identified by the batch, and the pages come from the durable
    /// record, so a caller cannot widen or narrow the scope it is resolving.
    ///
    /// - Parameters:
    ///   - scope: The recorded request to resolve, identified by its batch.
    ///   - storedPages: Every page the pen still stores, from a read that returned
    ///     the pen's whole inventory, or `nil` when the read did not complete or
    ///     did not cover the whole pen. A read that returns only new data is not an
    ///     inventory and must pass `nil`: a page it did not return may be one the
    ///     pen still holds, so an absent page only proves removal when the read saw
    ///     everything the pen has.
    /// - Returns: The resolved outcome, or `.outstanding` while removal is not
    ///   proven.
    public func resolveCleanup(
        _ scope: PenDeletionScope,
        storedPages: [PageIdentity]?
    ) async throws -> PenCleanupOutcome {
        let state: PenCleanupState?
        var recorded: PenDeletionScope?
        do {
            state = try await journal.latestState(batchID: scope.batchID)
            if state == .requested {
                recorded = try await journal.recordedScope(batchID: scope.batchID)
            }
        } catch let error as StorageError where error.isUnreadableCleanupRecord {
            // An unreadable row is an unknown effect, not an absent request.
            return .outstanding(reason: Self.unreadableJournalReason)
        }

        guard state == .requested else {
            return .skipped(reason: "no deletion request is outstanding for this read")
        }
        guard let recorded else {
            // The state says a request is outstanding, so a missing scope is a
            // journal this build cannot trust rather than "no request".
            return .outstanding(
                reason: "the journal records an outstanding request for this read, but its"
                    + " recorded scope is missing"
            )
        }

        guard let storedPages else {
            return .outstanding(
                reason: "the read did not cover the pen's whole inventory, so the removal of"
                    + " the recorded scope is not proven"
            )
        }

        let observed = Set(storedPages)
        let remaining = recorded.pages.filter { observed.contains($0) }
        guard remaining.isEmpty else {
            return .outstanding(
                reason: "\(remaining.count) of the recorded pages are still on the pen"
            )
        }

        try await journal.record(.confirmed, scope: recorded)
        return .reclaimed(pageCount: recorded.pageCount)
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
        return .saved(save, export: report)
    }

    public func retryExport(batchID: UUID, request: PenExportRequest) async throws -> PenExportReport {
        _ = try await retryableBatch(batchID)
        return try await publish(batchID, request: request)
    }

    // MARK: - Helpers

    /// The reason reported when a recorded cleanup request cannot be read back.
    ///
    /// The row says nothing this build can trust about whether a deletion was sent,
    /// so the effect is unknown rather than absent.
    private static let unreadableJournalReason =
        "the recorded cleanup request for this read cannot be read back"

    /// The reason reported when the sync was cancelled before the deletion was sent.
    ///
    /// A cancelled sync must put nothing on the wire, so the request is left
    /// outstanding rather than sent for a read the user ended.
    private static let cancelledReason =
        "the sync was cancelled before the deletion command was sent, so the pen's copy is"
            + " where it was and the request is not repeated automatically"

    /// The pages a read shares with any batch that has not published.
    ///
    /// A page can carry strokes from more than one sync. Deleting it for one read
    /// would also remove the strokes of a sync that has not completed, so a scope
    /// that touches such a page is refused.
    ///
    /// - Parameters:
    ///   - pages: The pages the candidate scope targets.
    ///   - batchID: The batch being cleaned up, which is not itself a conflict.
    /// - Returns: The shared pages, in canonical order.
    private func pagesSharedWithAnIncompleteSync(
        _ pages: [PageIdentity],
        excluding batchID: UUID
    ) async throws -> [PageIdentity] {
        let wanted = Set(pages)
        var shared = Set<PageIdentity>()
        for state in ImportBatchState.allCases where state != .published {
            for record in try await batches.batches(in: state) where record.batchID != batchID {
                shared.formUnion(wanted.intersection(record.pages))
            }
        }
        return shared.sorted(by: PageIdentity.canonicalOrder)
    }

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

extension StorageError {
    /// Whether the error means a cleanup record this build cannot decode.
    ///
    /// The cleanup path reports one as an unknown effect rather than as a cleanup
    /// that never ran, so the same request is never sent twice.
    fileprivate var isUnreadableCleanupRecord: Bool {
        switch self {
        case .unreadableCleanupState, .unreadableCleanupScope: return true
        case .cannotOpenDatabase, .statementFailed, .unsupportedSchemaVersion, .batchNotReady,
            .collectedStrokesUnavailable:
            return false
        }
    }
}
