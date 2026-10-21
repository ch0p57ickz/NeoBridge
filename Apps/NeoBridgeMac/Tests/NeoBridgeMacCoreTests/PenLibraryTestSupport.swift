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
    static func result(strokes: [Stroke], noteCount: Int = 1, penState: PenState? = nil) -> PenReadResult {
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
            transfer: PenReadTransfer(strokes: strokes, noteCount: noteCount),
            penState: penState
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

    /// A non-destructive read whose deleting route closed after the handshake.
    ///
    /// The session fell back to the ordinary option and named the blocker, so the
    /// result carries strokes and a refusal instead of a deleting batch.
    static func refusedDeletingResult(
        strokes: [Stroke],
        refusal: String,
        noteCount: Int = 1
    ) -> PenReadResult {
        var read = result(strokes: strokes, noteCount: noteCount)
        read = PenReadResult(
            summary: read.summary,
            transfer: read.transfer,
            penState: read.penState,
            deletingTransfer: nil,
            deletingReadRefusal: refusal
        )
        return read
    }

    /// A library save, for a stub whose import outcome a test never reads.
    static func save(batchID: UUID = UUID()) -> PenLibrarySave {
        PenLibrarySave(
            batchID: batchID,
            pages: [page],
            insertion: PenStrokeInsertion(addedStrokeCount: 1, duplicateStrokeCount: 0),
            strokeCount: 1,
            dotCount: 1
        )
    }

    /// A deleting read's result, carrying the durable prefix the session reported.
    ///
    /// A deleting read commits its packets as the transfer runs, so its result
    /// names the batch that already holds them rather than a transfer the library
    /// still has to import.
    ///
    /// - Parameter isComplete: Whether the transfer reached every end packet *and* that
    ///   completion was recorded.
    /// - Parameter reachedEndPacket: Whether the transfer reached every end packet,
    ///   whether or not the completion was recorded. It defaults to `isComplete`; pass
    ///   `true` with `isComplete: false` for a transfer whose completion write failed.
    static func deletingResult(
        strokes: [Stroke],
        packetCount: Int,
        isComplete: Bool,
        reachedEndPacket: Bool? = nil,
        acknowledgementUncertain: Bool = false,
        reason: String? = nil,
        batchID: UUID = UUID()
    ) -> PenReadResult {
        let dotCount = strokes.reduce(0) { $0 + $1.points.count }
        let pages = Set(strokes.map(\.page)).sorted(by: PageIdentity.canonicalOrder)
        let note = PenSyncNoteSummary(
            note: PenOfflineNote(section: 3, owner: 27, note: 700),
            strokeCount: strokes.count,
            dotCount: dotCount
        )

        return PenReadResult(
            summary: PenSyncSummary(
                strokeCount: strokes.count,
                dotCount: dotCount,
                distinctPageCount: pages.count,
                notes: strokes.isEmpty ? [] : [note]
            ),
            transfer: PenReadTransfer(strokes: strokes, noteCount: strokes.isEmpty ? 0 : 1),
            deletingTransfer: PenDeletingTransferReport(
                batchID: batchID,
                committedPacketCount: packetCount,
                committedStrokeCount: strokes.count,
                committedDotCount: dotCount,
                addedStrokeCount: strokes.count,
                duplicateStrokeCount: 0,
                pages: pages,
                isComplete: isComplete,
                reachedEndPacket: reachedEndPacket ?? isComplete,
                acknowledgementUncertain: acknowledgementUncertain,
                reason: reason
            )
        )
    }
}

/// A packet barrier that keeps the deleting route open for a shell test.
///
/// The shell tests never exercise the commit transaction itself — the storage
/// tests do — so this barrier only has to be present and report cumulative
/// progress, which is what makes ``PenDeletingReadStorage/isAvailable`` true.
actor StubPacketBarrier: PenDeletingPacketBarrier {
    private var packetCount = 0
    private var strokeCount = 0

    func beginDeletingRead(notes: [PenDeletingReadNote]) async throws -> UUID {
        packetCount = 0
        strokeCount = 0
        return UUID()
    }

    func commitDeletingPacket(
        _ packet: PenDeletingPacket
    ) async throws -> PenDeletingPacketCommitResult {
        packetCount += 1
        strokeCount += packet.strokes.count
        return PenDeletingPacketCommitResult(
            committedPacketCount: packetCount,
            committedStrokeCount: strokeCount,
            committedDotCount: packet.strokes.reduce(0) { $0 + $1.points.count },
            addedStrokeCount: packet.strokes.count,
            duplicateStrokeCount: 0,
            isEndPacket: packet.isEndPacket
        )
    }

    func finishDeletingRead(batchID: UUID, isComplete: Bool) async throws {}

    func failDeletingRead(batchID: UUID) async throws {}
}

extension PenDeletingReadStorage {
    /// Packet storage backed by a stub barrier, so a shell test sees the deleting
    /// route as available without exercising the commit transaction.
    static var stub: PenDeletingReadStorage {
        PenDeletingReadStorage(barrier: StubPacketBarrier())
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
    ///   - policy: The pen cleanup policy. The default is the closed gate.
    ///   - faultInjection: A fault the store raises, to model a storage failure.
    init(
        publisher: any PenExportPublisher = FilePenExportPublisher(),
        policy: PenCleanupPolicy = PenCleanupPolicy(),
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
            publisher: publisher,
            policy: policy
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
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a gate, closed unless a test wants one that is already open.
    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

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

    /// The cleanup outcome a request returns.
    let cleanup: PenCleanupOutcome

    /// The gate held open during the saving step.
    let saving: Gate

    /// The gate held open during the exporting step.
    let exporting: Gate

    /// The gate held open during a publication retry. It is open by default, so a
    /// test that does not watch the retry is not held up by it.
    let retry: Gate

    /// The report a publication retry returns.
    let retryReport: PenExportReport

    /// The report a deleting batch's publication returns.
    let publishReport: PenExportReport

    /// How many cleanup requests the controller has made.
    private var cleanupRequestCount = 0

    init(
        outcome: PenImportOutcome,
        cleanup: PenCleanupOutcome = .skipped(reason: "the deletion evidence gate is closed"),
        saving: Gate = Gate(),
        exporting: Gate = Gate(),
        retry: Gate = Gate(isOpen: true),
        retryReport: PenExportReport = PenExportReport(artifacts: []),
        publishReport: PenExportReport = PenExportReport(artifacts: [])
    ) {
        self.outcome = outcome
        self.cleanup = cleanup
        self.saving = saving
        self.exporting = exporting
        self.retry = retry
        self.retryReport = retryReport
        self.publishReport = publishReport
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
        publishReport
    }

    func requestCleanup(
        _ batchID: UUID,
        request: PenCleanupRequest
    ) async throws -> PenCleanupOutcome {
        cleanupRequestCount += 1
        // Retention is reported without consulting the scripted outcome, because
        // that is what the real importer does.
        return request.mode == .keepOnPen ? .retainedByChoice : cleanup
    }

    /// How many cleanup requests the controller has made.
    func requestedCleanupCount() -> Int { cleanupRequestCount }

    func retryExport(batchID: UUID, request: PenExportRequest) async throws -> PenExportReport {
        await retry.wait()
        return retryReport
    }
}
