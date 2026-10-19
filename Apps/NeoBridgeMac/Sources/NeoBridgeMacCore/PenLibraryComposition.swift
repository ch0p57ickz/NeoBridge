import Foundation
import NeoCore
import NeoExport
import NeoStorage

/// Builds the app's durable library and its export publisher.
///
/// The app owns the paths; the portable packages own the behaviour. Everything
/// here is testable without a radio, which is what lets the shell's save and
/// export paths be exercised on this host.
public enum PenLibraryComposition {
    /// The library file inside the app's Application Support directory.
    ///
    /// The directory is created on first use. Keeping the database outside the
    /// app bundle means an app update never touches the user's strokes.
    public static func defaultLibraryURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("NeoBridge", isDirectory: true)
            .appendingPathComponent("library.sqlite", isDirectory: false)
    }

    /// Opens the library and returns the verified importer over it.
    ///
    /// - Parameter libraryURL: The database file to open or create.
    /// - Throws: `StorageError` when the file cannot be opened or its schema is
    ///   newer than this build.
    public static func makeImporter(libraryURL: URL) throws -> PenLibraryImporter {
        let library = try SQLitePenLibrary(url: libraryURL)
        return PenLibraryImporter(
            store: library,
            batches: library,
            journal: library,
            publisher: FilePenExportPublisher()
        )
    }
}

/// An importer that refuses every read, for a library that could not be opened.
///
/// The app still scans and reads the pen; the failure it reports is the library's,
/// which is honest and actionable, rather than a silent memory-only result.
public struct UnavailableImportCoordinator: PenImportCoordinator {
    /// The path the library would have been opened at.
    public let libraryPath: String

    /// Why the library could not be opened.
    public let reason: String

    public init(libraryPath: String, reason: String) {
        self.libraryPath = libraryPath
        self.reason = reason
    }

    private var failure: StorageError {
        .cannotOpenDatabase(path: libraryPath, message: reason)
    }

    public func collect(_ strokes: [Stroke]) async throws -> ImportBatch {
        throw failure
    }

    public func validate(_ batchID: UUID) async throws {
        throw failure
    }

    public func commit(_ batchID: UUID) async throws {
        throw failure
    }

    public func publish(_ batchID: UUID, request: PenExportRequest) async throws -> PenExportReport {
        throw failure
    }

    public func acknowledge(_ batchID: UUID) async throws {
        throw failure
    }

    public func importRead(
        _ transfer: PenReadTransfer,
        export: PenExportRequest?,
        reporting: (@Sendable (PenImportStage) -> Void)?
    ) async throws -> PenImportOutcome {
        throw failure
    }

    public func retryExport(batchID: UUID, request: PenExportRequest) async throws -> PenExportReport {
        throw failure
    }
}
