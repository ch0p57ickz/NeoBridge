import Foundation

/// A complete, validated pen read that is ready to commit.
///
/// This is the host's hand-off from the protocol session to the library: it
/// carries every assembled stroke of one completed read, so nothing is
/// reconstructed from summary counts and no page identity is lost.
public struct PenReadTransfer: Hashable, Sendable {
    /// Every stroke the completed read assembled, in transfer order.
    public let strokes: [Stroke]

    /// How many offline notes the read covered.
    public let noteCount: Int

    public init(strokes: [Stroke], noteCount: Int) {
        self.strokes = strokes
        self.noteCount = noteCount
    }

    /// Strokes the read assembled.
    public var strokeCount: Int { strokes.count }

    /// Dots in those strokes.
    public var dotCount: Int {
        strokes.reduce(0) { total, stroke in total + stroke.points.count }
    }

    /// The distinct pages the strokes belong to, in canonical order.
    ///
    /// The order is by the four numeric key components, so it never depends on
    /// the order the pen transferred the strokes in.
    public var pages: [PageIdentity] {
        var seen = Set<PageIdentity>()
        return strokes
            .map(\.page)
            .filter { seen.insert($0).inserted }
            .sorted(by: PageIdentity.canonicalOrder)
    }

    /// Whether the read found no stroke at all.
    public var isEmpty: Bool { strokes.isEmpty }
}

/// What one commit added to the library.
public struct PenStrokeInsertion: Hashable, Sendable {
    /// Strokes the commit added.
    public let addedStrokeCount: Int

    /// Reliable strokes the commit recognized as already stored.
    ///
    /// A stroke whose identity is not reliable enough for cross-source
    /// deduplication is never counted here: it is always added, so its
    /// multiplicity survives a replay.
    public let duplicateStrokeCount: Int

    public init(addedStrokeCount: Int, duplicateStrokeCount: Int) {
        self.addedStrokeCount = addedStrokeCount
        self.duplicateStrokeCount = duplicateStrokeCount
    }

    /// Every stroke the commit examined.
    public var totalStrokeCount: Int { addedStrokeCount + duplicateStrokeCount }
}

/// The durable result of committing one read.
///
/// A save result means the strokes are stored. It says nothing about export:
/// publication is reported separately by ``PenExportReport``.
public struct PenLibrarySave: Hashable, Sendable {
    /// The batch the read was committed as, which a later publication retry
    /// names.
    public let batchID: UUID

    /// The pages the committed strokes belong to, in canonical order.
    public let pages: [PageIdentity]

    /// What the commit added.
    public let insertion: PenStrokeInsertion

    /// Strokes the read carried.
    public let strokeCount: Int

    /// Dots the read carried.
    public let dotCount: Int

    public init(
        batchID: UUID,
        pages: [PageIdentity],
        insertion: PenStrokeInsertion,
        strokeCount: Int,
        dotCount: Int
    ) {
        self.batchID = batchID
        self.pages = pages
        self.insertion = insertion
        self.strokeCount = strokeCount
        self.dotCount = dotCount
    }

    /// Whether the read stored no new stroke because every reliable stroke was
    /// already in the library.
    public var isFullyDuplicate: Bool { insertion.addedStrokeCount == 0 }
}

/// One page's stored strokes, ready to render.
public struct PenPageContent: Hashable, Sendable {
    /// The canonical page the strokes belong to.
    public let page: PageIdentity

    /// The stored strokes for that page.
    public let strokes: [Stroke]

    public init(page: PageIdentity, strokes: [Stroke]) {
        self.page = page
        self.strokes = strokes
    }

    /// Whether the page has no stored stroke, in which case it produces no file.
    public var isEmpty: Bool { strokes.isEmpty }

    /// Dots in the page's strokes.
    public var dotCount: Int {
        strokes.reduce(0) { total, stroke in total + stroke.points.count }
    }
}

/// What one complete import ended with.
///
/// The two outcomes are deliberately separate. A commit that succeeded is a
/// saved result even when publication fails afterwards, and export completion
/// is reported only when every requested file is published.
public enum PenImportOutcome: Hashable, Sendable {
    /// The read committed. `export` carries the publication result, or `nil`
    /// when no publication was requested.
    case saved(PenLibrarySave, export: PenExportReport?)

    /// The read completed and carried no stroke, so nothing was stored and no
    /// file was written.
    case noStrokesFound

    /// The committed library result, when the read was stored.
    public var save: PenLibrarySave? {
        if case .saved(let save, _) = self { return save }
        return nil
    }

    /// The publication result, when one was requested.
    public var export: PenExportReport? {
        if case .saved(_, let export) = self { return export }
        return nil
    }

    /// Whether the read is stored in the library.
    public var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }
}

/// One durable record of an import batch.
///
/// The record is what makes import progress survive a restart: a batch that
/// reached `committed` can publish its exports again without re-reading the pen.
public struct PenImportBatchRecord: Hashable, Sendable {
    /// Stable identifier for the batch.
    public let batchID: UUID

    /// The lifecycle state the batch reached.
    public let state: ImportBatchState

    /// How the batch's strokes arrived.
    public let kind: ImportTransferKind

    /// How far the batch's transfer got, independently of its publication.
    public let completion: ImportBatchCompletion

    /// The pages the batch's strokes belong to, in canonical order.
    public let pages: [PageIdentity]

    /// Strokes the batch carried.
    public let strokeCount: Int

    /// Dots the batch carried.
    public let dotCount: Int

    /// The packets a deleting transfer durably committed, in commit order.
    ///
    /// An ordinary batch has none. A deleting batch has one entry per
    /// acknowledged packet, which is what lets a restart report the acknowledged
    /// prefix rather than a completed read.
    public let packets: [PenImportPacketProgress]

    public init(
        batchID: UUID,
        state: ImportBatchState,
        kind: ImportTransferKind = .ordinary,
        completion: ImportBatchCompletion = .complete,
        pages: [PageIdentity],
        strokeCount: Int,
        dotCount: Int,
        packets: [PenImportPacketProgress] = []
    ) {
        self.batchID = batchID
        self.state = state
        self.kind = kind
        self.completion = completion
        self.pages = pages
        self.strokeCount = strokeCount
        self.dotCount = dotCount
        self.packets = packets
    }

    /// Whether the batch came from a deleting transfer.
    public var isDeletingTransfer: Bool { kind == .deleting }

    /// Whether at least one packet is durably committed.
    public var hasDurablePackets: Bool { !packets.isEmpty }

    /// Whether the transfer reached every discovered note's end packet.
    public var isTransferComplete: Bool { completion == .complete }

    /// Whether the batch can still be published from its stored rows.
    ///
    /// A committed batch whose publication failed, and a published batch whose
    /// files were replaced afterwards, both qualify. A deleting batch qualifies
    /// as soon as one packet is durable, even while its transfer is partial,
    /// because the committed pages are already re-exportable.
    public var isPublicationRetryable: Bool {
        guard state == .committed || state == .published else { return false }
        if kind == .deleting { return hasDurablePackets }
        return true
    }

    /// Whether the batch's pages may not be reclaimed by a separate deletion
    /// command yet.
    ///
    /// A deleting batch is never eligible for a separate command, and a batch
    /// whose transfer is still `inProgress` or `partial` is incomplete even when
    /// its publication succeeded, so a page it shares is not safe to remove.
    public var blocksCommandDeletionScope: Bool {
        if kind == .deleting { return true }
        return state != .published || completion != .complete
    }
}
