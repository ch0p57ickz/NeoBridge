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

/// How one batch's strokes arrived.
///
/// The kind is orthogonal to ``ImportBatchState``, which stays the publication
/// lifecycle. An ordinary batch is stored in one commit; a deleting batch is
/// stored packet by packet as its transfer runs, so its publication and its
/// completion can disagree.
public enum ImportTransferKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// A complete read committed in one transaction.
    case ordinary

    /// A deleting `0x23` transfer committed one acknowledged packet at a time.
    case deleting
}

/// How far a batch's transfer got, independently of its publication.
///
/// A deleting batch reaches `committed` on its first durable packet and may
/// publish while still incomplete, so completion is its own durable field:
/// `inProgress` while the transfer runs, `partial` when it stopped before every
/// note's end packet, and `complete` only when every discovered note ended.
public enum ImportBatchCompletion: String, Hashable, Sendable, Codable, CaseIterable {
    /// The transfer has not finished and has not been abandoned.
    case inProgress

    /// The transfer stopped before every note's end packet.
    case partial

    /// Every discovered note reached its end packet.
    case complete
}

/// One packet a deleting transfer durably committed.
public struct PenImportPacketProgress: Hashable, Sendable, Codable {
    /// The pen's section-owner identifier for the packet's note.
    public let sectionOwnerID: UInt32

    /// The pen's note identifier.
    public let noteID: UInt32

    /// The pen's packet identifier within the transfer.
    public let packetID: UInt16

    /// Strokes the packet carried.
    public let strokeCount: Int

    /// Whether the packet declared itself the transfer's last.
    public let isEndPacket: Bool

    public init(
        sectionOwnerID: UInt32,
        noteID: UInt32,
        packetID: UInt16,
        strokeCount: Int,
        isEndPacket: Bool
    ) {
        self.sectionOwnerID = sectionOwnerID
        self.noteID = noteID
        self.packetID = packetID
        self.strokeCount = strokeCount
        self.isEndPacket = isEndPacket
    }
}

/// One note a deleting read plans to cover.
public struct PenDeletingReadNote: Hashable, Sendable {
    /// The pen's section-owner identifier.
    public let sectionOwnerID: UInt32

    /// The pen's note identifier.
    public let noteID: UInt32

    public init(sectionOwnerID: UInt32, noteID: UInt32) {
        self.sectionOwnerID = sectionOwnerID
        self.noteID = noteID
    }
}

/// One accepted packet a deleting transfer hands to durable storage.
///
/// The packet is the unit the pen bounds its removal by, so it is also the unit
/// the library commits: the whole packet's strokes, its progress, and its end
/// marker go into one transaction that returns only after a durable sync, and the
/// session acknowledges the packet only once that call has returned.
public struct PenDeletingPacket: Hashable, Sendable {
    /// The batch this packet belongs to.
    public let batchID: UUID

    /// The pen's section-owner identifier for the packet's note.
    public let sectionOwnerID: UInt32

    /// The pen's note identifier.
    public let noteID: UInt32

    /// The pen's packet identifier.
    public let packetID: UInt16

    /// Every stroke the packet carried.
    public let strokes: [Stroke]

    /// Whether this packet declared itself the transfer's last.
    public let isEndPacket: Bool

    public init(
        batchID: UUID,
        sectionOwnerID: UInt32,
        noteID: UInt32,
        packetID: UInt16,
        strokes: [Stroke],
        isEndPacket: Bool
    ) {
        self.batchID = batchID
        self.sectionOwnerID = sectionOwnerID
        self.noteID = noteID
        self.packetID = packetID
        self.strokes = strokes
        self.isEndPacket = isEndPacket
    }

    /// The distinct pages the packet's strokes belong to, in canonical order.
    public var pages: [PageIdentity] {
        var seen = Set<PageIdentity>()
        return strokes
            .map(\.page)
            .filter { seen.insert($0).inserted }
            .sorted(by: PageIdentity.canonicalOrder)
    }
}

/// What one durable packet commit left in the batch.
///
/// The counts are what this batch added to the library, not what the pen handed
/// over: a fresh read that replays a packet the pen never had acknowledged finds
/// those strokes already stored, so the replay adds nothing and the batch that
/// stores the remainder reports only its own strokes. That is what keeps a
/// reported save honest after a crash.
public struct PenDeletingPacketCommitResult: Hashable, Sendable {
    /// Packets committed for the batch so far, including this one.
    public let committedPacketCount: Int

    /// Strokes this batch added to the library so far, including this one's.
    public let committedStrokeCount: Int

    /// Dots in the strokes this batch added so far.
    public let committedDotCount: Int

    /// Strokes this packet added.
    public let addedStrokeCount: Int

    /// Reliable strokes this packet recognized as already stored.
    public let duplicateStrokeCount: Int

    /// Whether this packet declared itself the transfer's last.
    public let isEndPacket: Bool

    public init(
        committedPacketCount: Int,
        committedStrokeCount: Int,
        committedDotCount: Int,
        addedStrokeCount: Int,
        duplicateStrokeCount: Int,
        isEndPacket: Bool
    ) {
        self.committedPacketCount = committedPacketCount
        self.committedStrokeCount = committedStrokeCount
        self.committedDotCount = committedDotCount
        self.addedStrokeCount = addedStrokeCount
        self.duplicateStrokeCount = duplicateStrokeCount
        self.isEndPacket = isEndPacket
    }
}

/// The durable packet storage a deleting read commits through.
///
/// The value is what the app composes and hands to a deleting read: the barrier
/// when a writable library is available, and the reason it is not when it is not.
/// A deleting read is refused rather than narrowed when the storage is absent.
public struct PenDeletingReadStorage: Sendable {
    /// The barrier each packet is committed through, or `nil` when unavailable.
    public let barrier: (any PenDeletingPacketBarrier)?

    /// Why no barrier is available, or `nil` when one is.
    public let unavailableReason: String?

    public init(
        barrier: (any PenDeletingPacketBarrier)?,
        unavailableReason: String? = nil
    ) {
        self.barrier = barrier
        self.unavailableReason = unavailableReason
    }

    /// A configuration with no durable packet storage.
    public static let unavailable = PenDeletingReadStorage(barrier: nil)

    /// Whether a deleting read can commit its packets.
    public var isAvailable: Bool { barrier != nil }
}

/// The storage barrier a deleting transfer commits each packet through.
///
/// The session awaits this before it builds or sends a packet's `0xA4`, so a
/// packet is only ever acknowledged after its strokes and progress are durable.
/// A failure, a cancellation, or an unavailable database leaves the packet
/// unacknowledged, which is what keeps the pen from removing data the library
/// does not hold.
public protocol PenDeletingPacketBarrier: Sendable {
    /// Opens a deleting batch for a read and returns its identifier.
    func beginDeletingRead(notes: [PenDeletingReadNote]) async throws -> UUID

    /// Commits one accepted packet's strokes and progress in one durable
    /// transaction.
    ///
    /// - Returns: The batch's cumulative progress, once the commit has returned
    ///   after a durable sync.
    func commitDeletingPacket(_ packet: PenDeletingPacket) async throws
        -> PenDeletingPacketCommitResult

    /// Marks the batch's completion once the transfer has stopped.
    ///
    /// - Parameter isComplete: Whether every discovered note reached its end
    ///   packet. `false` leaves the batch `partial`.
    func finishDeletingRead(batchID: UUID, isComplete: Bool) async throws

    /// Marks the batch failed because the read that opened it ended before its
    /// first durable packet.
    ///
    /// A deleting read opens its batch before the first `0x23`, so a read that ends
    /// without committing a packet — a dropped link, a refused or malformed
    /// response, a failed first commit, or a cancellation at the first inbound wait
    /// — leaves a batch that can never publish and claims a transfer that has
    /// ended. The row is marked rather than removed, because the journal and a later
    /// diagnosis need to see that the read was attempted.
    ///
    /// An implementation MUST leave every other batch exactly as it is: an ordinary
    /// batch, a batch with a durable packet, and a batch whose read already
    /// finished are all outside this call's meaning, so calling it for them writes
    /// nothing, and a second call for the same batch is a no-op.
    func failDeletingRead(batchID: UUID) async throws
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
