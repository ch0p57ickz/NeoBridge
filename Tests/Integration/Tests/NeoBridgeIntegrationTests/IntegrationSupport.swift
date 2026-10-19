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

    /// Creates a workspace.
    ///
    /// - Parameter publisher: The export publisher. The default writes files.
    init(publisher: any PenExportPublisher = FilePenExportPublisher()) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neobridge-integration", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        library = try SQLitePenLibrary(url: root.appendingPathComponent("library.sqlite"))
        importer = PenLibraryImporter(
            store: library,
            batches: library,
            journal: library,
            publisher: publisher
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
