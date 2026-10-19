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

    public init(summary: PenSyncSummary, transfer: PenReadTransfer) {
        self.summary = summary
        self.transfer = transfer
    }

    /// Splits an assembled session result into the summary and the transfer.
    public init(_ result: PenSessionResult) {
        self.summary = PenSyncSummary(result)
        self.transfer = PenReadTransfer(
            strokes: result.strokes,
            noteCount: result.notes.count
        )
    }
}

/// What one finished read left behind, in the shape the shell presents.
///
/// Storage and export are separate outcomes on purpose: a read that committed is
/// saved even when a file could not be written, and export success is claimed only
/// when every requested file is in place.
public struct PenReadOutcome: Hashable, Sendable {
    /// The counts and notes the read found.
    public let summary: PenSyncSummary

    /// The committed library result, or `nil` when the read stored nothing.
    public let save: PenLibrarySave?

    /// The publication result, or `nil` when no export was requested.
    public let export: PenExportReport?

    /// The folder files were published into, when one was chosen.
    public let destinationDirectory: String?

    public init(
        summary: PenSyncSummary,
        save: PenLibrarySave?,
        export: PenExportReport?,
        destinationDirectory: String?
    ) {
        self.summary = summary
        self.save = save
        self.export = export
        self.destinationDirectory = destinationDirectory
    }

    /// Whether the read found no stroke, so nothing was stored.
    public var isEmpty: Bool { save == nil }

    /// Whether the read is stored in the library.
    public var isSaved: Bool { save != nil }

    /// Whether the read asked for files to be written.
    public var requestedExport: Bool { destinationDirectory != nil }

    /// Whether every requested file is in place.
    public var exportSucceeded: Bool { export?.succeeded ?? false }

    /// Whether a requested publication failed.
    public var exportFailed: Bool { requestedExport && !exportSucceeded }

    /// Whether publication can be attempted again from the stored rows.
    public var canRetryExport: Bool { save != nil && destinationDirectory != nil }

    /// A one-line statement of what happened, for the menu and the window.
    public var notice: String {
        guard let save else {
            return "The read found no strokes, so nothing was saved and no files were written."
        }

        let saved = "Saved \(save.strokeCount) stroke\(save.strokeCount == 1 ? "" : "s")"
            + " across \(save.pages.count) page\(save.pages.count == 1 ? "" : "s") to the library."

        guard let destinationDirectory else {
            return saved + " No export folder has been chosen, so no files were written."
        }

        guard let export else {
            return saved
        }

        if export.succeeded {
            return saved + " Wrote \(export.artifacts.count) file"
                + "\(export.artifacts.count == 1 ? "" : "s") to \(destinationDirectory)."
        }

        let failed = export.failed.count
        return saved + " \(failed) of \(export.artifacts.count) file"
            + "\(export.artifacts.count == 1 ? "" : "s") could not be written to"
            + " \(destinationDirectory)."
    }
}
