import Foundation

/// Portable boundaries for the import, storage, export, and pen-cleanup work that
/// follows this package initialization.
///
/// The interfaces stay free of platform types so a Linux test can drive them with
/// in-memory fakes. They describe the two-phase verified import that the design
/// requires: collect and validate a batch, commit records, publish deterministic
/// exports atomically, then request cleanup for the batch. Cleanup is journaled
/// and its deletion command stays unreachable until the evidence gate in
/// ``PenDeletionEvidence`` proves it safe.

/// The lifecycle of one verified import batch.
public enum ImportBatchState: String, Hashable, Sendable, Codable, CaseIterable {
    /// Strokes are being collected and normalized.
    case collecting

    /// The collected batch passed validation and is ready to commit.
    case validated

    /// Records are committed to storage.
    case committed

    /// Exports for the batch are published.
    case published

    /// The batch failed and must not have its pen copy reclaimed.
    case failed

    /// The allowed transitions out of this state.
    public var allowedNextStates: Set<ImportBatchState> {
        switch self {
        case .collecting:
            return [.validated, .failed]
        case .validated:
            return [.committed, .failed]
        case .committed:
            return [.published, .failed]
        case .published, .failed:
            return []
        }
    }
}

/// A refused import state transition.
public enum ImportBatchTransitionError: Error, Hashable, Sendable {
    /// The requested transition is not part of the batch lifecycle.
    case illegalTransition(from: ImportBatchState, to: ImportBatchState)
}

/// A portable, in-memory import batch state machine.
public struct ImportBatch: Sendable, Hashable {
    /// Stable identifier for the batch.
    public let id: UUID

    /// The current lifecycle state.
    public private(set) var state: ImportBatchState

    public init(id: UUID = UUID(), state: ImportBatchState = .collecting) {
        self.id = id
        self.state = state
    }

    /// Moves the batch to another state.
    ///
    /// - Throws: `ImportBatchTransitionError.illegalTransition` when the move is
    ///   not allowed from the current state.
    public mutating func transition(to next: ImportBatchState) throws {
        guard state.allowedNextStates.contains(next) else {
            throw ImportBatchTransitionError.illegalTransition(from: state, to: next)
        }
        state = next
    }
}

/// A storage boundary for assembled strokes.
///
/// An insert is one transaction: either every stroke of the call is stored or
/// none is. A reliable stroke whose canonical fingerprint is already stored is
/// not stored twice, while a stroke whose identity is not reliable enough for
/// cross-source deduplication is always added, so a replay cannot collapse two
/// different marks into one.
public protocol PenStrokeStore: Sendable {
    /// Stores strokes in one transaction.
    ///
    /// - Returns: What the insert added and what it recognized as already
    ///   stored.
    func insert(_ strokes: [Stroke]) async throws -> PenStrokeInsertion

    /// Returns the strokes stored for a page, in insertion order.
    func strokes(on page: PageIdentity) async throws -> [Stroke]

    /// Returns every stored page, in canonical order.
    func pages() async throws -> [PageIdentity]
}

/// A durable record of import progress.
///
/// The store keeps each batch's state, so a restart can tell a committed batch
/// whose publication failed from a transfer that never completed.
public protocol PenImportBatchStore: Sendable {
    /// Records a batch, replacing any earlier record for the same batch.
    func save(_ record: PenImportBatchRecord) async throws

    /// Returns a batch's record, or `nil` when the batch is unknown.
    func batch(id: UUID) async throws -> PenImportBatchRecord?

    /// Returns every batch in a state, oldest first.
    func batches(in state: ImportBatchState) async throws -> [PenImportBatchRecord]
}

/// The export formats the app will publish.
public enum PenExportFormat: String, Hashable, Sendable, Codable, CaseIterable {
    case json
    case svg
    case markdown
}

/// A request to publish exports for a set of pages.
public struct PenExportRequest: Hashable, Sendable {
    /// The formats to publish.
    ///
    /// The app publishes every format for every non-empty page and offers no
    /// format choice, so the default is all three.
    public let formats: [PenExportFormat]

    /// The pages to export. A page with no stored stroke produces no file.
    public let pages: [PageIdentity]

    /// Destination directory for the published files.
    public let destinationDirectory: String

    public init(
        formats: [PenExportFormat] = PenExportFormat.allCases,
        pages: [PageIdentity],
        destinationDirectory: String
    ) {
        self.formats = formats
        self.pages = pages
        self.destinationDirectory = destinationDirectory
    }
}

/// An export boundary that publishes files atomically.
///
/// A publisher never throws for a per-file problem: it reports every requested
/// target in the returned report, so the caller can distinguish a written file
/// from a failed one and retry.
public protocol PenExportPublisher: Sendable {
    /// Publishes every requested format for the given page content.
    ///
    /// - Parameters:
    ///   - request: The formats, pages, and destination directory.
    ///   - content: The stored strokes for the pages to render. A requested page
    ///     that is missing or has no stroke produces no file.
    /// - Returns: One artifact per requested target.
    func publish(_ request: PenExportRequest, content: [PenPageContent]) async -> PenExportReport
}

/// A step of a verified import that a caller can present.
public enum PenImportStage: String, Hashable, Sendable, CaseIterable {
    /// The read's strokes are being committed to the library.
    case saving

    /// The read's page files are being published.
    case exporting
}

/// Coordinates the verified import lifecycle.
///
/// The lifecycle is two-phase: collect and validate every note transfer, then
/// commit the whole read in one transaction and publish its exports from a fresh
/// read of the stored rows.
public protocol PenImportCoordinator: Sendable {
    /// Starts a batch and records the collected strokes.
    func collect(_ strokes: [Stroke]) async throws -> ImportBatch

    /// Marks a batch as validated.
    func validate(_ batchID: UUID) async throws

    /// Commits a validated batch to storage.
    func commit(_ batchID: UUID) async throws

    /// Publishes exports for a committed batch.
    func publish(_ batchID: UUID, request: PenExportRequest) async throws -> PenExportReport

    /// Requests cleanup of a published batch's verified data.
    ///
    /// The call records the exact scope durably before anything can be sent, marks
    /// it requested before bytes can reach the pen, and marks it confirmed only
    /// when an evidence-backed response proves the recorded scope was removed.
    /// Nothing is sent for a batch that is not published, for a sync that chose
    /// retention, or while the deletion evidence gate is closed; each of those is
    /// reported as its own outcome instead.
    ///
    /// - Parameters:
    ///   - batchID: The batch whose verified data cleanup targets.
    ///   - request: The intent for this sync and the channel to send over.
    /// - Returns: What the cleanup ended with. A non-confirming send leaves the
    ///   request outstanding rather than reporting reclamation.
    /// - Throws: When the batch is unknown, so a cleanup can never be recorded
    ///   against data that was not stored.
    func requestCleanup(_ batchID: UUID, request: PenCleanupRequest) async throws -> PenCleanupOutcome

    /// Imports one complete, validated read.
    ///
    /// - Parameters:
    ///   - transfer: The read's strokes and note count.
    ///   - export: The publication to attempt, or `nil` to store only.
    ///   - reporting: Called as each import step begins, so a caller can present
    ///     saving and exporting separately.
    /// - Returns: A saved result with the publication outcome, or
    ///   `noStrokesFound` when the read carried no stroke.
    /// - Throws: A storage error. A read that is not stored throws instead of
    ///   reporting a save, and a publication problem is reported rather than
    ///   thrown.
    func importRead(
        _ transfer: PenReadTransfer,
        export: PenExportRequest?,
        reporting: (@Sendable (PenImportStage) -> Void)?
    ) async throws -> PenImportOutcome

    /// Publishes a committed batch again from its stored rows.
    ///
    /// - Throws: When the batch is unknown or never committed, so a retry can
    ///   never invent a result from data that was not stored.
    func retryExport(batchID: UUID, request: PenExportRequest) async throws -> PenExportReport
}

extension PenImportCoordinator {
    /// Imports one complete read without reporting its steps.
    public func importRead(
        _ transfer: PenReadTransfer,
        export: PenExportRequest?
    ) async throws -> PenImportOutcome {
        try await importRead(transfer, export: export, reporting: nil)
    }
}

// The cleanup mode, its durable journal states, the deletion evidence gate, and
// the cleanup policy live in `PenCleanup.swift`.
