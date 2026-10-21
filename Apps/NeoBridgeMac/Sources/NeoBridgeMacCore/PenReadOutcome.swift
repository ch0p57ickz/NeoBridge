import Foundation
import NeoCore
import NeoProtocol

/// What one completed read produced.
///
/// The summary is what the shell presents; the transfer is the complete set of
/// assembled strokes the library commits. Keeping both on one result is what
/// stops the host boundary from reducing a read to its counts.
public struct PenReadResult: Hashable, Sendable {
    /// The counts and notes the shell presents.
    public let summary: PenSyncSummary

    /// The complete transfer, ready to commit.
    public let transfer: PenReadTransfer

    /// The pen's battery and storage reading for this attempt.
    public let penState: PenState?

    /// What a deleting read durably committed, or `nil` for an ordinary read.
    ///
    /// A deleting read commits its packets as the transfer runs, so its transfer
    /// is already stored and must not be imported a second time.
    public let deletingTransfer: PenDeletingTransferReport?

    /// Why a requested deleting read took the ordinary non-destructive path, or
    /// `nil` when no deleting read was requested or one ran.
    ///
    /// The connected pen's identity is only known after the handshake, so a pen the
    /// transfer evidence does not cover is the one blocker that cannot be decided
    /// before connecting. The read continues non-destructively and this is the
    /// reason the shell reports.
    public let deletingReadRefusal: String?

    public init(
        summary: PenSyncSummary,
        transfer: PenReadTransfer,
        penState: PenState? = nil,
        deletingTransfer: PenDeletingTransferReport? = nil,
        deletingReadRefusal: String? = nil
    ) {
        self.summary = summary
        self.transfer = transfer
        self.penState = penState
        self.deletingTransfer = deletingTransfer
        self.deletingReadRefusal = deletingReadRefusal
    }

    /// Splits an assembled session result into the summary and the transfer.
    public init(_ result: PenSessionResult) {
        self.summary = PenSyncSummary(result)
        self.penState = result.penState
        self.transfer = PenReadTransfer(
            strokes: result.strokes,
            noteCount: result.notes.count
        )
        self.deletingTransfer = result.deletingTransfer
        self.deletingReadRefusal = result.deletingReadRefusal
    }

    /// Whether this read already committed its packets through a deleting
    /// transfer.
    public var isDeletingRead: Bool { deletingTransfer != nil }
}

/// What one finished read left behind, in the shape the shell presents.
///
/// Storage and export are separate outcomes on purpose: a read that committed is
/// saved even when a file could not be written, and export success is claimed only
/// when every requested file is in place. Cleanup is a third outcome for the same
/// reason: whether the pen's copy was reclaimed says nothing about whether the
/// library copy is safe.
public struct PenReadOutcome: Hashable, Sendable {
    /// The counts and notes the read found.
    public let summary: PenSyncSummary

    /// The pen's battery and storage reading for this completed attempt.
    public let penState: PenState?

    /// The committed library result, or `nil` when the read stored nothing.
    public let save: PenLibrarySave?

    /// The publication result, or `nil` when no export was requested.
    public let export: PenExportReport?

    /// What happened to the pen's copy of the verified data.
    public let cleanup: PenCleanupOutcome

    /// The folder files were published into, when one was chosen.
    public let destinationDirectory: String?

    /// What a deleting read durably committed, or `nil` for an ordinary read.
    ///
    /// The report is what lets the shell distinguish a durable acknowledged
    /// prefix from a completed saved read, and an uncertain last acknowledgement
    /// from a confirmed one.
    public let deletingTransfer: PenDeletingTransferReport?

    public init(
        summary: PenSyncSummary,
        save: PenLibrarySave?,
        export: PenExportReport?,
        cleanup: PenCleanupOutcome,
        destinationDirectory: String?,
        penState: PenState? = nil,
        deletingTransfer: PenDeletingTransferReport? = nil
    ) {
        self.summary = summary
        self.penState = penState
        self.save = save
        self.export = export
        self.cleanup = cleanup
        self.destinationDirectory = destinationDirectory
        self.deletingTransfer = deletingTransfer
    }

    /// Whether the read found no stroke, so nothing was stored.
    public var isEmpty: Bool { save == nil }

    /// Whether the read is stored in the library.
    public var isSaved: Bool { save != nil }

    /// Whether this read used a deleting transfer.
    public var isDeletingRead: Bool { deletingTransfer != nil }

    /// Whether a deleting read has no durably recorded completion.
    ///
    /// It is `true` for a transfer that stopped short and for one that reached its end
    /// packet whose completion could not be recorded. ``reachedEndPacket`` tells the two
    /// apart, which is what stops the two from being reported with one explanation.
    public var isPartialDeletingRead: Bool {
        guard let deletingTransfer else { return false }
        return !deletingTransfer.isComplete
    }

    /// Whether the read asked for files to be written.
    public var requestedExport: Bool { destinationDirectory != nil }

    /// Whether every requested file is in place.
    public var exportSucceeded: Bool { export?.succeeded ?? false }

    /// Whether a requested publication failed.
    public var exportFailed: Bool { requestedExport && !exportSucceeded }

    /// Whether publication can be attempted again from the stored rows.
    public var canRetryExport: Bool { save != nil && destinationDirectory != nil }

    /// Whether the pen's copy was reclaimed.
    public var reclaimedPenCopy: Bool { cleanup.isReclaimed }

    /// A one-line statement of what happened to the pen's copy.
    ///
    /// It is kept separate from ``notice`` because the two are independent: a read
    /// can be saved and exported while the pen keeps its copy, and a reclaimed pen
    /// copy says nothing about whether a file was written.
    public var cleanupNotice: String { cleanup.summary }

    /// A one-line statement of what happened, for the menu and the window.
    public var notice: String {
        guard let save else {
            return "The read found no strokes, so nothing was saved and no files were written."
        }

        let saved = "Saved \(save.strokeCount) stroke\(save.strokeCount == 1 ? "" : "s")"
            + " across \(save.pages.count) page\(save.pages.count == 1 ? "" : "s") to the library."

        let publication = exportNotice(destinationDirectory: destinationDirectory)

        guard let deletingTransfer else {
            return saved + publication
        }

        let removal: String
        if deletingTransfer.isComplete {
            removal = "The acknowledged packets were removed from the pen as the read ran;"
                + " the library copy remains available."
        } else if deletingTransfer.reachedEndPacket {
            // The transfer finished, so the pen holds no remainder: this read is
            // incomplete because the durable record of it could not be written, and the
            // reason names that failure rather than blaming the pen.
            let cause = deletingTransfer.reason ?? "the read's completion could not be recorded"
            removal = "The transfer reached the last packet, so the pen holds no remainder of it;"
                + " the read is reported as incomplete because \(cause)."
        } else {
            removal = "The read stopped before the end, so only its acknowledged packets were"
                + " removed and the pen may still hold the remainder."
        }
        let uncertainty = deletingTransfer.acknowledgementUncertain
            ? " The last packet's acknowledgement was not confirmed, so the pen's copy of it is"
                + " uncertain."
            : ""
        return saved + " " + removal + uncertainty + publication
    }

    /// The publication sentence for a read, given its destination and export.
    private func exportNotice(destinationDirectory: String?) -> String {
        guard let destinationDirectory else {
            return " No export folder has been chosen, so no files were written."
        }

        guard let export else {
            return ""
        }

        if export.succeeded {
            return " Wrote \(export.artifacts.count) file"
                + "\(export.artifacts.count == 1 ? "" : "s") to \(destinationDirectory)."
        }

        let failed = export.failed.count
        return " \(failed) of \(export.artifacts.count) file"
            + "\(export.artifacts.count == 1 ? "" : "s") could not be written to"
            + " \(destinationDirectory)."
    }
}
