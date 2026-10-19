import Foundation
import NeoCore
import NeoProtocol

/// What a completed read found, in the shape the shell presents.
///
/// The counts are the ones `PenSessionResult` derived from the accepted `0x24`
/// packets, never from the lagging `0xA3` summary. This type carries only what
/// the shell shows, so the presentation model stays app-owned and the portable
/// result stays a protocol artifact.
public struct PenSyncSummary: Hashable, Sendable {
    /// Strokes assembled from the accepted packets.
    public let strokeCount: Int

    /// Dots in those strokes.
    public let dotCount: Int

    /// Distinct canonical pages the assembled strokes belong to.
    public let distinctPageCount: Int

    /// One entry per note that was read, in the order the pen listed them.
    public let notes: [PenSyncNoteSummary]

    /// Creates a summary.
    public init(
        strokeCount: Int,
        dotCount: Int,
        distinctPageCount: Int,
        notes: [PenSyncNoteSummary]
    ) {
        self.strokeCount = strokeCount
        self.dotCount = dotCount
        self.distinctPageCount = distinctPageCount
        self.notes = notes
    }

    /// Summarizes an assembled session result.
    public init(_ result: PenSessionResult) {
        self.init(
            strokeCount: result.strokeCount,
            dotCount: result.dotCount,
            distinctPageCount: result.distinctPageCount,
            notes: result.notes.map(PenSyncNoteSummary.init)
        )
    }

    /// Whether the pen reported no offline note at all.
    public var isEmpty: Bool { notes.isEmpty }
}

/// One note's contribution to a completed read.
public struct PenSyncNoteSummary: Hashable, Sendable, Identifiable {
    /// The note that was read.
    public let note: PenOfflineNote

    /// Strokes the transfer carried.
    public let strokeCount: Int

    /// Dots in those strokes.
    public let dotCount: Int

    /// The note's identity, which never includes a Bluetooth address.
    public var id: PenOfflineNote { note }

    /// A label for the notes-read list.
    public var label: String { note.displayLabel }

    /// Creates a note summary.
    public init(note: PenOfflineNote, strokeCount: Int, dotCount: Int) {
        self.note = note
        self.strokeCount = strokeCount
        self.dotCount = dotCount
    }

    /// Summarizes one transfer.
    public init(_ transfer: PenNoteTransfer) {
        self.init(
            note: transfer.note,
            strokeCount: transfer.strokeCount,
            dotCount: transfer.dotCount
        )
    }
}

extension PenOfflineNote {
    /// A label for the notes-read list.
    ///
    /// A note is identified by Ncode section, owner, and note number, so the
    /// pen's Bluetooth address cannot appear here.
    public var displayLabel: String {
        "Note \(note) · section \(section) · owner \(owner)"
    }
}
