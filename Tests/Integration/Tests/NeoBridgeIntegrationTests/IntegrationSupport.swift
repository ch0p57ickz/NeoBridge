import Foundation
import NeoCore
import NeoExport
import NeoProtocol
import NeoStorage

/// Loads the repository's sanitized fixtures and builds the stores the scenarios
/// use.
enum IntegrationFixtures {
    /// The repository fixture directory.
    ///
    /// The path is derived from this file's location so a scenario does not depend
    /// on the process working directory.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NeoBridgeIntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Integration
            .deletingLastPathComponent() // Tests (repository)
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Tests/Fixtures", isDirectory: true)
    }

    /// Every fixture, sorted by file name.
    static func all() throws -> [ProtocolFixture] {
        try ProtocolFixtureLoader.loadAll(in: directory)
    }

    /// The whole offline read path fixture.
    static func offlineSession() throws -> ProtocolFixture {
        let fixtures = try all()
        guard let fixture = fixtures.first(where: { $0.id == "a1-offline-session" }) else {
            throw IntegrationError.missingFixture("a1-offline-session")
        }
        return fixture
    }
}

/// The commands a transport sent, decoded rather than indexed.
enum OutboundCommands {
    /// Every command identifier a transport sent, in order.
    static func decode(_ chunks: [[UInt8]]) -> [PenCommand?] {
        chunks.map { chunk in
            var decoder = PenFrameDecoder()
            guard case .frame(let frame)? = decoder.ingest(chunk).first else { return nil }
            return frame.command
        }
    }

    /// Every frame a transport sent, decoded.
    static func frames(_ chunks: [[UInt8]]) -> [PenFrame] {
        chunks.compactMap { chunk in
            var decoder = PenFrameDecoder()
            guard case .frame(let frame)? = decoder.ingest(chunk).first else { return nil }
            return frame
        }
    }
}

/// A durable library and an export folder in a temporary directory.
struct IntegrationWorkspace {
    /// The temporary root.
    let root: URL

    /// The durable library.
    let library: SQLitePenLibrary

    /// The importer and publisher the scenarios drive.
    let importer: PenLibraryImporter

    /// The export folder.
    let exportDirectory: URL

    /// The cleanup policy every importer over this library is built with.
    let policy: PenCleanupPolicy

    /// Creates a workspace.
    ///
    /// - Parameters:
    ///   - publisher: The export publisher. The default writes files.
    ///   - policy: The pen cleanup policy, so a scenario can open the evidence
    ///     gate. The default is the closed gate.
    init(
        publisher: any PenExportPublisher = FilePenExportPublisher(),
        policy: PenCleanupPolicy = PenCleanupPolicy()
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neobridge-integration", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        self.policy = policy
        library = try SQLitePenLibrary(url: root.appendingPathComponent("library.sqlite"))
        importer = PenLibraryImporter(
            store: library,
            batches: library,
            journal: library,
            publisher: publisher,
            policy: policy
        )
    }

    /// Another importer over the same library, with a different publisher.
    ///
    /// A scenario uses this to make one note publish and a later one fail without
    /// giving the two notes different libraries.
    func importer(publisher: any PenExportPublisher) -> PenLibraryImporter {
        PenLibraryImporter(
            store: library,
            batches: library,
            journal: library,
            publisher: publisher,
            policy: policy
        )
    }

    /// An export request for a set of pages into this workspace.
    func exportRequest(pages: [PageIdentity]) -> PenExportRequest {
        PenExportRequest(pages: pages, destinationDirectory: exportDirectory.path)
    }

    /// The file names in the export folder, sorted.
    func exportedFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path).sorted()
    }

    /// Every exported file's contents, concatenated as text.
    func exportedText() throws -> String {
        try exportedFiles()
            .map { name in
                let url = exportDirectory.appendingPathComponent(name)
                return String(decoding: try Data(contentsOf: url), as: UTF8.self)
            }
            .joined(separator: "\n")
    }

    /// Removes the temporary root.
    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// A failure raised by the integration harness.
enum IntegrationError: Error, Hashable {
    case missingFixture(String)
}

/// A deletion channel that records every request and confirms it.
///
/// It stands in for a pen whose `0xA5`/`0xA7` response is proven to mean that
/// exactly the recorded scope was removed.
struct RecordingDeletionSender: PenDeletionSender {
    /// Every deletion the sender was asked for.
    let calls: IntegrationDeletionCalls

    init(calls: IntegrationDeletionCalls = IntegrationDeletionCalls()) {
        self.calls = calls
    }

    func delete(_ scope: PenDeletionScope) async throws -> PenDeletionOutcome {
        await calls.record(scope)
        return .confirmed(scope)
    }
}

/// Records the deletion scopes a recording sender was asked for.
actor IntegrationDeletionCalls {
    private var scopes: [PenDeletionScope] = []

    /// Records one deletion request.
    func record(_ scope: PenDeletionScope) {
        scopes.append(scope)
    }

    /// Every deletion scope, in order.
    var allScopes: [PenDeletionScope] { scopes }
}

/// A publisher that fails every target, so no export ever publishes.
struct FailingExportPublisher: PenExportPublisher {
    /// Why every target fails.
    var reason = "the destination is unavailable"

    func publish(_ request: PenExportRequest, content: [PenPageContent]) async -> PenExportReport {
        PenExportReport(
            artifacts: request.formats.map { format in
                PenExportArtifact(
                    format: format,
                    path: "\(request.destinationDirectory)/page.\(format.rawValue)",
                    byteCount: 0,
                    status: .failed(reason: reason)
                )
            }
        )
    }
}

/// The evidence record that opens the deletion gate for one scope.
///
/// The verdicts stand in for the physical A1 traces the gate requires; the
/// integration scenarios use them to exercise the deletion path end to end.
///
/// - Parameter target: The deletion command the traces proved.
/// - Returns: A record whose every condition is `safe`.
func openDeletionGate(target: PenDeletionTarget = .note) -> PenDeletionEvidence {
    PenDeletionEvidence(
        target: target,
        verdicts: Dictionary(
            uniqueKeysWithValues: PenDeletionCondition.allCases.map { ($0, .safe) }
        )
    )
}
