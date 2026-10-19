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

    /// Runs a session and imports what it read.
    ///
    /// - Parameters:
    ///   - transport: The byte channel to the pen.
    ///   - versionPolicy: The validated-minor policy the version gate applies.
    ///   - penClockIsTrusted: Whether the pen's clock may be trusted for
    ///     cross-source deduplication.
    ///   - export: The publication to attempt, or `nil` to store only.
    ///   - reporting: Called as each import step begins.
    /// - Returns: The session result and the import outcome.
    /// - Throws: A session error, a storage error, or a cancellation. A
    ///   per-file publication problem is reported in the outcome rather than
    ///   thrown.
    public func run(
        transport: PenTransport,
        versionPolicy: ProtocolVersionPolicy = .neoSDK3,
        penClockIsTrusted: Bool = true,
        export: PenExportRequest?,
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
        return ImportedSession(result: result, outcome: outcome)
    }
}

/// What one session left behind.
public struct ImportedSession: Hashable, Sendable {
    /// The assembled session result.
    public let result: PenSessionResult

    /// The committed and published outcome.
    public let outcome: PenImportOutcome

    public init(result: PenSessionResult, outcome: PenImportOutcome) {
        self.result = result
        self.outcome = outcome
    }
}
