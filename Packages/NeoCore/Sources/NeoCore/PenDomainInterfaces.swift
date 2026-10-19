import Foundation

/// Portable boundaries for the import, storage, export, and pen-cleanup work that
/// follows this package initialization.
///
/// The interfaces stay free of platform types so a Linux test can drive them with
/// in-memory fakes. They describe the two-phase verified import that the design
/// requires: collect and validate a batch, commit records, publish deterministic
/// exports atomically, then acknowledge the batch. Pen cleanup is journaled and
/// stays disabled until physical A1 acceptance passes.

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

    /// The batch failed and must not be acknowledged to the pen.
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
public protocol PenStrokeStore: Sendable {
    /// Inserts strokes, replacing any stroke with the same fingerprint.
    func insert(_ strokes: [Stroke]) async throws

    /// Returns the strokes stored for a page, in insertion order.
    func strokes(on page: PageIdentity) async throws -> [Stroke]
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
    public let formats: [PenExportFormat]

    /// The pages to export.
    public let pages: [PageIdentity]

    /// Destination directory for the published files.
    public let destinationDirectory: String

    public init(formats: [PenExportFormat], pages: [PageIdentity], destinationDirectory: String) {
        self.formats = formats
        self.pages = pages
        self.destinationDirectory = destinationDirectory
    }
}

/// One published export file.
public struct PenExportArtifact: Hashable, Sendable {
    /// The format of the published file.
    public let format: PenExportFormat

    /// The path of the published file.
    public let path: String

    /// The size of the published file in bytes.
    public let byteCount: Int

    public init(format: PenExportFormat, path: String, byteCount: Int) {
        self.format = format
        self.path = path
        self.byteCount = byteCount
    }
}

/// An export boundary that publishes files atomically.
public protocol PenExportPublisher: Sendable {
    /// Publishes every requested format for the given strokes.
    ///
    /// Implementations write sibling temporary files and rename them into place
    /// before returning, so a reader never observes a partial export.
    func publish(_ request: PenExportRequest, strokes: [Stroke]) async throws -> [PenExportArtifact]
}

/// Coordinates the verified import lifecycle.
public protocol PenImportCoordinator: Sendable {
    /// Starts a batch and records the collected strokes.
    func collect(_ strokes: [Stroke]) async throws -> ImportBatch

    /// Marks a batch as validated.
    func validate(_ batchID: UUID) async throws

    /// Commits a validated batch to storage.
    func commit(_ batchID: UUID) async throws

    /// Publishes exports for a committed batch.
    func publish(_ batchID: UUID, request: PenExportRequest) async throws -> [PenExportArtifact]

    /// Acknowledges a published batch so the pen may release its copy.
    func acknowledge(_ batchID: UUID) async throws
}

/// How the app treats strokes that are already stored on the pen.
public enum PenCleanupMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Leave strokes on the pen. This is the default.
    case keepOnPen

    /// Request deletion after the batch is acknowledged.
    case deleteAfterAcknowledge
}

/// The durable states of a pen cleanup request.
public enum PenCleanupState: String, Hashable, Sendable, Codable, CaseIterable {
    /// A cleanup request is recorded but not yet sent.
    case prepared

    /// A cleanup request has been sent to the pen.
    case requested

    /// The pen confirmed the cleanup.
    case confirmed
}

/// The pen cleanup policy.
///
/// The policy defaults to `keepOnPen`. Deletion stays disabled until physical A1
/// acceptance passes, so `deletionEnabled` is `false` for every policy this
/// package can construct.
public struct PenCleanupPolicy: Hashable, Sendable {
    /// The configured mode.
    public let mode: PenCleanupMode

    public init(mode: PenCleanupMode = .keepOnPen) {
        self.mode = mode
    }

    /// Whether the app may send a deletion request to the pen.
    ///
    /// Always `false` in this change. Physical A1 acceptance must pass before a
    /// later change can enable deletion.
    public var deletionEnabled: Bool {
        false
    }
}

/// A durable journal for pen cleanup requests.
public protocol PenCleanupJournal: Sendable {
    /// Records a cleanup state for a batch.
    func record(_ state: PenCleanupState, batchID: UUID) async throws

    /// Returns the most recently recorded state for a batch.
    func latestState(batchID: UUID) async throws -> PenCleanupState?
}
