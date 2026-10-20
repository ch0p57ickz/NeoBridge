import NeoCore
import NeoProtocol

/// Runs one whole pen session over a transport and commits its result.
///
/// This is the portable integration seam: it joins the session to the library and
/// the export publisher exactly as the app does, without any platform type, so an
/// end-to-end read can be verified on Linux over a fake transport.
public struct OfflineSessionImport: Sendable {
    /// The importer that stores the read and publishes its files.
    private let importer: any PenImportCoordinator

    /// Creates a session import.
    ///
    /// - Parameter importer: The verified importer that stores the read and
    ///   publishes its requested files.
    public init(importer: any PenImportCoordinator) {
        self.importer = importer
    }

    /// Runs a session, imports what it read, then applies its cleanup request.
    ///
    /// The cleanup step comes after the import so the ordering rule is the
    /// integration seam's own property: the pen's copy is only ever reclaimed for
    /// a read that has committed durably and published an export in full.
    ///
    /// - Parameters:
    ///   - transport: The byte channel to the pen.
    ///   - versionPolicy: The validated-minor policy the version gate applies.
    ///   - penClockIsTrusted: Whether the pen's clock may be trusted for
    ///     cross-source deduplication.
    ///   - export: The publication to attempt, or `nil` to store only.
    ///   - cleanup: How this sync treats the pen's copy, or `nil` to request no
    ///     cleanup at all.
    ///   - reporting: Called as each import step begins.
    /// - Returns: The session result, the import outcome, and the cleanup outcome.
    /// - Throws: A session error, a storage error, or a cancellation. A
    ///   per-file publication problem is reported in the outcome rather than
    ///   thrown.
    public func run(
        transport: PenTransport,
        versionPolicy: ProtocolVersionPolicy = .neoSDK3,
        penClockIsTrusted: Bool = true,
        export: PenExportRequest?,
        cleanup: PenCleanupRequest? = nil,
        reporting: (@Sendable (PenImportStage) -> Void)? = nil
    ) async throws -> ImportedSession {
        let session = PenSession(
            transport: transport,
            versionPolicy: versionPolicy,
            penClockIsTrusted: penClockIsTrusted
        )
        let result = try await session.run()
        let transfer = PenReadTransfer(strokes: result.strokes, noteCount: result.notes.count)
        let outcome = try await importer.importRead(transfer, export: export, reporting: reporting)

        // A read that stored nothing has no scope to clean up, so it requests no
        // deletion.
        let cleanupOutcome: PenCleanupOutcome?
        if let cleanup, let batchID = outcome.save?.batchID {
            cleanupOutcome = try await importer.requestCleanup(batchID, request: cleanup)
        } else {
            cleanupOutcome = nil
        }

        return ImportedSession(result: result, outcome: outcome, cleanup: cleanupOutcome)
    }
}

/// What one session left behind.
public struct ImportedSession: Hashable, Sendable {
    /// The assembled session result.
    public let result: PenSessionResult

    /// The committed and published outcome.
    public let outcome: PenImportOutcome

    /// What the cleanup step ended with, or `nil` when the caller requested none
    /// or the read stored nothing.
    public let cleanup: PenCleanupOutcome?

    public init(
        result: PenSessionResult,
        outcome: PenImportOutcome,
        cleanup: PenCleanupOutcome? = nil
    ) {
        self.result = result
        self.outcome = outcome
        self.cleanup = cleanup
    }
}
