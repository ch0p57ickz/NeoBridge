import Foundation
import NeoBridgeMacCore
import NeoCore
import NeoExport
import NeoProtocol
import NeoStorage

/// Builds the read results and strokes the shell tests use.
enum TestRead {
    /// The captured page the fixtures describe.
    static let page = PageIdentity(section: 3, owner: 27, book: 700, page: 1)

    /// A stroke with one point on a page.
    static func stroke(
        x: Int32 = 10,
        page: PageIdentity? = nil,
        origin: PenOriginTime = .reliable(milliseconds: 1_700_000_000_000)
    ) -> Stroke {
        Stroke(
            page: page ?? self.page,
            originTime: origin,
            points: [PenPoint(x: x, y: 0, penTimeOffsetMilliseconds: 0, pressure: 4)],
            source: .offline
        )
    }

    /// A read result carrying strokes, with the counts a real read would report.
    static func result(strokes: [Stroke], noteCount: Int = 1) -> PenReadResult {
        let dotCount = strokes.reduce(0) { $0 + $1.points.count }
        let pageCount = Set(strokes.map(\.page)).count
        let note = PenSyncNoteSummary(
            note: PenOfflineNote(section: 3, owner: 27, note: 700),
            strokeCount: strokes.count,
            dotCount: dotCount
        )

        return PenReadResult(
            summary: PenSyncSummary(
                strokeCount: strokes.count,
                dotCount: dotCount,
                distinctPageCount: pageCount,
                notes: noteCount == 0 ? [] : [note]
            ),
            transfer: PenReadTransfer(strokes: strokes, noteCount: noteCount)
        )
    }

    /// One stroke of ``twelveStrokeResult()``.
    private static func twelveStroke(index: Int) -> Stroke {
        let page = PageIdentity(section: 3, owner: 27, book: 700, page: UInt32(index % 3))
        let origin = PenOriginTime.reliable(milliseconds: 1_700_000_000_000 + Int64(index))
        let points: [PenPoint] = (0..<20).map { offset in
            PenPoint(
                x: Int32(index * 20 + offset),
                y: Int32(offset),
                penTimeOffsetMilliseconds: Int64(offset),
                pressure: 7
            )
        }
        return Stroke(page: page, originTime: origin, points: points, source: .offline)
    }

    /// The summary the earlier shell tests used: twelve strokes over three pages.
    static func twelveStrokeResult() -> PenReadResult {
        let strokes: [Stroke] = (0..<12).map(twelveStroke(index:))

        let note = PenSyncNoteSummary(
            note: PenOfflineNote(section: 3, owner: 27, note: 700),
            strokeCount: 12,
            dotCount: 240
        )
        return PenReadResult(
            summary: PenSyncSummary(
                strokeCount: 12,
                dotCount: 240,
                distinctPageCount: 3,
                notes: [note]
            ),
            transfer: PenReadTransfer(strokes: strokes, noteCount: 1)
        )
    }
}

/// A publisher whose per-format outcomes a test scripts.
struct StubPenExportPublisher: PenExportPublisher {
    /// The formats that fail on the first publication, and why.
    var failures: [PenExportFormat: String] = [:]

    /// The real publisher that writes the files once a scripted failure is over.
    private let writer = FilePenExportPublisher()
    private let attempts = PublicationAttemptCounter()

    func publish(_ request: PenExportRequest, content: [PenPageContent]) async -> PenExportReport {
        let isFirstAttempt = await attempts.begin()
        guard isFirstAttempt, !failures.isEmpty else {
            return await writer.publish(request, content: content)
        }

        // A scripted failure reports the failing targets and writes the rest, so a
        // test sees the same per-file shape a real failure produces. A failing
        // target is left as it was, so a file the failure would have created is
        // removed rather than left behind.
        let report = await writer.publish(request, content: content)
        return PenExportReport(
            artifacts: report.artifacts.map { artifact in
                guard let reason = failures[artifact.format] else { return artifact }
                if artifact.status == .published {
                    try? FileManager.default.removeItem(atPath: artifact.path)
                }
                return PenExportArtifact(
                    format: artifact.format,
                    path: artifact.path,
                    byteCount: artifact.byteCount,
                    status: .failed(reason: reason)
                )
            }
        )
    }
}

/// Counts publications so a scripted failure can be limited to the first one.
actor PublicationAttemptCounter {
    private var count = 0

    /// Records one publication.
    ///
    /// - Returns: Whether this is the first publication.
    func begin() -> Bool {
        count += 1
        return count == 1
    }
}

/// A durable library in a temporary directory, with a temporary export folder.
@MainActor
struct TestLibrary {
    /// The temporary root the library and exports live in.
    let root: URL

    /// The SQLite library the importer writes to.
    let library: SQLitePenLibrary

    /// The importer the controller drives.
    let importer: PenLibraryImporter

    /// The export folder.
    let exportDirectory: URL

    /// Opens a library and an export folder.
    ///
    /// - Parameters:
    ///   - publisher: The publisher to publish through. The default writes files.
    ///   - faultInjection: A fault the store raises, to model a storage failure.
    init(
        publisher: any PenExportPublisher = FilePenExportPublisher(),
        faultInjection: (@Sendable (Int) throws -> Void)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neobridge-app-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        library = try SQLitePenLibrary(
            url: root.appendingPathComponent("library.sqlite"),
            faultInjection: faultInjection
        )
        importer = PenLibraryImporter(
            store: library,
            batches: library,
            journal: library,
            publisher: publisher
        )
    }

    /// The destination a controller should use for this library.
    var destination: any PenExportDestinationProviding {
        FixedExportDestination(directory: exportDirectory.path)
    }

    /// The file names in the export folder, sorted.
    func exportedFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path).sorted()
    }

    /// Removes the temporary root.
    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// A failure a test injects into the store.
enum InjectedStorageFailure: Error, Hashable {
    case stopped
}

/// A one-shot gate that suspends an import until a test opens it.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until ``open()`` is called.
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Releases every waiter and lets later waiters through at once.
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// An import coordinator whose saving and exporting steps wait for a test.
///
/// The real importer reports those steps too, but it runs them to completion
/// within one call, so a test cannot reliably catch the transient phases. This
/// stub holds each step open until the test has observed the phase it drives.
actor StubImportCoordinator: PenImportCoordinator {
    /// What the import ends with.
    let outcome: PenImportOutcome

    /// The gate held open during the saving step.
    let saving: Gate

    /// The gate held open during the exporting step.
    let exporting: Gate

    init(outcome: PenImportOutcome, saving: Gate = Gate(), exporting: Gate = Gate()) {
        self.outcome = outcome
        self.saving = saving
        self.exporting = exporting
    }

    func importRead(
        _ transfer: PenReadTransfer,
        export: PenExportRequest?,
        reporting: (@Sendable (PenImportStage) -> Void)?
    ) async throws -> PenImportOutcome {
        reporting?(.saving)
        await saving.wait()
        if export != nil {
            reporting?(.exporting)
            await exporting.wait()
        }
        return outcome
    }

    func collect(_ strokes: [Stroke]) async throws -> ImportBatch { ImportBatch() }

    func validate(_ batchID: UUID) async throws {}

    func commit(_ batchID: UUID) async throws {}

    func publish(_ batchID: UUID, request: PenExportRequest) async throws -> PenExportReport {
        PenExportReport(artifacts: [])
    }

    func acknowledge(_ batchID: UUID) async throws {}

    func retryExport(batchID: UUID, request: PenExportRequest) async throws -> PenExportReport {
        PenExportReport(artifacts: [])
    }
}
