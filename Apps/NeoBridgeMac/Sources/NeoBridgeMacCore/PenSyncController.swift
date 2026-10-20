import Foundation
import NeoCore
import NeoProtocol
import Observation

/// Drives one read attempt and publishes what the shell shows.
///
/// The controller owns the attempt lifecycle — start, cancel, retry — and no
/// protocol, storage, or file logic. It reads one runner per attempt from its
/// factory, so every retry starts a new scan and a new session, and it hands the
/// complete transfer to the library, so a read is saved rather than summarized.
@MainActor
@Observable
public final class PenSyncController {
    /// What the shell is showing.
    public enum Phase: Hashable, Sendable {
        /// No attempt has started, or the user cancelled one.
        case idle

        /// Scanning for a pen advertising the expected name.
        case scanning

        /// Sending the version request and awaiting its response.
        case connecting

        /// Checking the reported protocol version.
        case verifying

        /// Discovering notes and reading their offline data.
        case syncing

        /// Committing the read to the library.
        case saving

        /// Publishing the read's page files.
        case exporting

        /// Several pens advertised the expected name, so the user chooses one.
        ///
        /// No pen is picked silently, and no candidate carries an address.
        case choosingPen(candidates: [PenPeripheral])

        /// The read finished. The outcome says whether it was stored and whether
        /// every requested file was written.
        case complete(PenReadOutcome)

        /// A step failed. `diagnostic` describes partial data when a transfer
        /// stopped early, and is never presented as a completed sync.
        case failed(message: String, diagnostic: String?)

        /// Whether the attempt has stopped and will do no more work.
        public var isTerminal: Bool {
            switch self {
            case .complete, .failed: return true
            case .idle, .scanning, .connecting, .verifying, .syncing, .saving, .exporting,
                .choosingPen:
                return false
            }
        }
    }

    /// The title of the action that retrieves offline strokes.
    ///
    /// The label says the app saves the pen's data, because that is what the read
    /// does now: the strokes are committed to the library and the requested files
    /// are written.
    public static let readActionTitle = "Read and Save Pen Data"

    /// The title of the action that publishes a stored read again.
    public static let retryExportActionTitle = "Retry Export"

    /// The title of the action that keeps the pen's copy for the current read.
    public static let retainPenDataTitle = "Keep Strokes on the Pen for This Read"

    /// What the shell says before a transfer about the pen's copy.
    ///
    /// The statement is about the intent, not a promise: the deletion runs only
    /// after the read is stored and its files are written, and only when the
    /// evidence gate is open. When the gate is closed, ``cleanupUnavailableReason``
    /// says why.
    public static let cleanupIntentStatement =
        "Strokes are normally removed from the pen after they are saved and their files are written."

    /// What the shell is showing now.
    public private(set) var phase: Phase = .idle

    /// The measured state from the current completed read, if available.
    public var penState: PenState? { outcome?.penState }

    /// The cleanup intent the shell shows, which is the one the next transfer uses.
    ///
    /// It is the read in flight's intent while one runs, the completed read's intent
    /// while its files can still be published again — so a retry finishes that read
    /// with the intent it was given — and the next read's intent at every other
    /// moment. Every choice the shell offers is honoured by whoever uses it.
    public var cleanupIntent: PenCleanupMode {
        if isBusy || isRetryableCompletion { return attemptCleanupMode }
        return nextReadCleanupMode
    }

    /// The intent the next read will use.
    ///
    /// It starts at the policy's default, which is cleanup. A choice made while no
    /// read is in flight replaces it, and the read that consumes it restores the
    /// default, so no stale choice is inherited by a later sync.
    private var nextReadCleanupMode: PenCleanupMode

    /// The intent the read in flight, or the completed read a retry can still
    /// finish, uses.
    ///
    /// It is captured when the read starts, so the value the read requested cannot
    /// change while it runs, and it is what its own retry uses unless the user
    /// chooses otherwise.
    private var attemptCleanupMode: PenCleanupMode

    /// Whether the phase is a completed read whose files a retry can still publish.
    private var isRetryableCompletion: Bool {
        if case .complete = phase { return canRetryExport }
        return false
    }

    private let runners: PenSyncRunnerFactory
    private let library: any PenImportCoordinator
    private let destination: any PenExportDestinationProviding
    private let cleanupPolicy: PenCleanupPolicy
    private var attempt: Task<Void, Never>?
    private var generation = 0

    /// Creates a controller.
    ///
    /// - Parameters:
    ///   - runners: The factory that makes a runner for each attempt.
    ///   - library: The verified importer that stores a read and publishes it.
    ///   - destination: The folder exports are written to.
    ///   - cleanupPolicy: The pen cleanup policy. Its mode is the intent a sync
    ///     that makes no choice gets, and its evidence gate decides whether the
    ///     pen's copy can be reclaimed at all.
    public init(
        runners: PenSyncRunnerFactory,
        library: any PenImportCoordinator,
        destination: any PenExportDestinationProviding,
        cleanupPolicy: PenCleanupPolicy = PenCleanupPolicy()
    ) {
        self.runners = runners
        self.library = library
        self.destination = destination
        self.cleanupPolicy = cleanupPolicy
        self.nextReadCleanupMode = cleanupPolicy.mode
        self.attemptCleanupMode = cleanupPolicy.mode
    }

    /// Whether the pen's copy can be reclaimed while the evidence gate is open.
    public var isCleanupAvailable: Bool { cleanupPolicy.deletionEnabled }

    /// Why cleanup cannot run, or `nil` when it can.
    public var cleanupUnavailableReason: String? {
        cleanupPolicy.skipReason(for: .deleteAfterAcknowledge)
    }

    /// Whether the current sync intends to reclaim the pen's copy.
    public var isCleanupIntended: Bool { cleanupIntent == .deleteAfterAcknowledge }

    /// Whether the shell offers a cleanup choice.
    ///
    /// A choice made while a read is in flight would not reach that read, which
    /// captured its intent when it started, so only that state withholds the choice.
    /// Every offered choice is honoured: the retry of a completed read uses the one
    /// made for it, and the next read uses any other.
    public var canChooseCleanup: Bool { !isBusy }

    /// A one-line statement of the intent the shell is showing.
    ///
    /// It names what the choice applies to, because that differs: a read that is
    /// running already captured its intent, a completed read whose files can still be
    /// published again hands the choice to its retry, and every other moment hands it
    /// to the next read.
    public var cleanupIntentLine: String {
        if isBusy {
            return isCleanupIntended
                ? "Removing the pen's strokes when this read completes."
                : "Keeping the pen's strokes for this read."
        }
        if isRetryableCompletion {
            return isCleanupIntended
                ? "Retry Export removes the pen's strokes once it publishes."
                : "Retry Export keeps the pen's strokes."
        }
        return isCleanupIntended
            ? "The next read removes the pen's strokes after they are saved."
            : "The next read keeps the pen's strokes."
    }

    /// Chooses retention.
    ///
    /// A choice made while a read is running would not reach that read, so it is
    /// ignored rather than silently applied to the next one.
    public func retainPenDataForThisSync() {
        chooseCleanupIntent(.keepOnPen)
    }

    /// Chooses cleanup.
    public func intendCleanupForThisSync() {
        chooseCleanupIntent(.deleteAfterAcknowledge)
    }

    /// Applies a choice to the transfer the shell shows it against.
    ///
    /// A choice made while a completed read can still be published again belongs to
    /// that retry; at every other moment it belongs to the next read.
    private func chooseCleanupIntent(_ mode: PenCleanupMode) {
        guard !isBusy else { return }
        if isRetryableCompletion {
            attemptCleanupMode = mode
        } else {
            nextReadCleanupMode = mode
        }
    }

    /// Whether an attempt is running.
    public var isBusy: Bool {
        switch phase {
        case .scanning, .connecting, .verifying, .syncing, .saving, .exporting: return true
        case .idle, .choosingPen, .complete, .failed: return false
        }
    }

    /// Whether the app is waiting for the user to choose between pens.
    public var isAwaitingChoice: Bool {
        if case .choosingPen = phase { return true }
        return false
    }

    /// The pens that matched, when the app is waiting for a choice.
    public var penCandidates: [PenPeripheral] {
        if case .choosingPen(let candidates) = phase { return candidates }
        return []
    }

    /// A short status line for the menu and the window.
    public var statusLabel: String {
        switch phase {
        case .idle: return "Idle"
        case .scanning: return PenSyncStage.scanning.label
        case .connecting: return PenSyncStage.connecting.label
        case .verifying: return PenSyncStage.verifying.label
        case .syncing: return PenSyncStage.syncing.label
        case .saving: return "Saving to the library"
        case .exporting: return "Writing export files"
        case .choosingPen: return "Choose a pen"
        case .complete: return "Complete"
        case .failed: return "Failed"
        }
    }

    /// The finished read, when the attempt succeeded.
    public var outcome: PenReadOutcome? {
        if case .complete(let outcome) = phase { return outcome }
        return nil
    }

    /// The failure message, when the attempt failed.
    public var errorMessage: String? {
        if case .failed(let message, _) = phase { return message }
        return nil
    }

    /// The partial-data diagnostic for a failed attempt, when there is one.
    public var errorDiagnostic: String? {
        if case .failed(_, let diagnostic) = phase { return diagnostic }
        return nil
    }

    /// The folder exports are written to, or `nil` when none has been chosen.
    public var exportDirectoryPath: String? {
        destination.exportDirectory()
    }

    /// Whether a stored read can have its files published again.
    ///
    /// The retry is offered only while the completed read is the one shown, so a
    /// later failed attempt cannot leave a Retry action that republishes an older
    /// read and reports it as the current result.
    public var canRetryExport: Bool {
        guard case .complete(let outcome) = phase else { return false }
        return outcome.canRetryExport && outcome.exportFailed
    }

    /// Stores the folder the user chose.
    ///
    /// - Parameter url: The chosen folder.
    /// - Throws: When the folder cannot be remembered, so the app never claims a
    ///   destination it cannot reopen.
    public func chooseExportDirectory(_ url: URL) throws {
        try destination.setExportDirectory(url)
    }

    /// Starts a read attempt.
    ///
    /// A call while a choice is pending does nothing, so a read cannot skip the
    /// question about which pen to use.
    public func readPenData() {
        guard !isAwaitingChoice else { return }
        start(selection: .automatic)
    }

    /// Reads the pen the user chose after several matched.
    ///
    /// The intent the user set survives the question, because the attempt had not
    /// started when it was asked.
    ///
    /// - Parameter peripheral: A candidate from ``penCandidates``.
    public func choosePen(_ peripheral: PenPeripheral) {
        guard isAwaitingChoice else { return }
        start(selection: .explicit(peripheral))
    }

    /// Stops the running attempt and returns to idle.
    ///
    /// The published phase is set at once and the attempt's generation is
    /// retired, so a late callback from the cancelled attempt cannot overwrite
    /// this state or report a completion.
    public func cancel() {
        guard isBusy || isAwaitingChoice else { return }
        attempt?.cancel()
        settle()
        // The cancelled sync consumed its choice, so the next read starts from the
        // policy's default again.
        nextReadCleanupMode = cleanupPolicy.mode
        generation += 1
        phase = .idle
    }

    /// Publishes the last stored read's files again.
    ///
    /// The retry reads the committed rows, so it never imports the read twice and
    /// never invents a result from data that was not stored. A retry that completes
    /// the publication finishes the same read, so it requests cleanup for the
    /// intent the shell is showing: the displayed intent is the one that is used,
    /// so a retention choice made after a failed export is honoured here instead
    /// of being discarded.
    public func retryExport() {
        guard canRetryExport, case .complete(let outcome) = phase, let save = outcome.save,
            let directory = outcome.destinationDirectory
        else { return }

        generation += 1
        let generation = self.generation
        // The retry finishes the read that is shown, so it uses the intent the shell
        // is showing for it: the read's own intent, or a choice made at the end of
        // that read. Capturing it keeps the value fixed even if the shell is tapped
        // again while the retry runs.
        let mode = cleanupIntent
        phase = .exporting

        let request = PenExportRequest(pages: save.pages, destinationDirectory: directory)
        attempt = Task { [weak self] in
            guard let controller = self else { return }
            do {
                let report = try await controller.library.retryExport(
                    batchID: save.batchID,
                    request: request
                )
                // A cancelled retry stops here: the user ended this sync, so nothing
                // more may reach the pen for it.
                guard controller.generation == generation else { return }

                let cleanup: PenCleanupOutcome
                if report.succeeded {
                    cleanup = await controller.requestCleanup(for: save.batchID, mode: mode)
                } else if mode == .keepOnPen {
                    // The retry did not publish, so no deletion was requested and
                    // the retention the user chose still stands for this read.
                    cleanup = .retainedByChoice
                } else {
                    // The pen's copy is where the read left it, so its outcome stands.
                    cleanup = outcome.cleanup
                }
                controller.finishRetry(
                    with: report,
                    cleanup: cleanup,
                    for: generation,
                    base: outcome
                )
            } catch {
                controller.fail(with: error, for: generation)
            }
        }
    }

    // MARK: - Attempt

    private func start(selection: CoreBluetoothPenTransport.Selection) {
        guard !isBusy else { return }

        // The read consumes the intent the shell was showing for it, and the shell
        // goes back to the policy's default while the read runs: the choice was for
        // this read, so a later one never inherits it.
        attemptCleanupMode = nextReadCleanupMode
        nextReadCleanupMode = cleanupPolicy.mode

        generation += 1
        let generation = self.generation
        phase = .scanning

        let runner = runners.makeRunner(selection: selection)
        attempt = Task { [weak self] in
            guard let controller = self else { return }

            // The stages arrive from the runner's own context, so each report
            // hops back to the main actor. Reports are ordered because the
            // session reports its states in order.
            let report: @Sendable (PenSyncStage) -> Void = { [weak self] stage in
                Task { @MainActor in
                    self?.apply(stage, for: generation)
                }
            }

            do {
                let read = try await runner.run(report: report)
                try await controller.save(read, for: generation)
            } catch {
                controller.fail(with: error, for: generation)
            }
        }
    }

    /// Commits the read, publishes its files, and requests cleanup.
    private func save(_ read: PenReadResult, for generation: Int) async throws {
        guard self.generation == generation else { return }

        let directory = destination.exportDirectory()
        let request = directory.map {
            PenExportRequest(pages: read.transfer.pages, destinationDirectory: $0)
        }

        let reporting: @Sendable (PenImportStage) -> Void = { [weak self] stage in
            Task { @MainActor in
                self?.apply(stage, for: generation)
            }
        }

        let outcome = try await library.importRead(
            read.transfer,
            export: request,
            reporting: reporting
        )

        guard self.generation == generation else { return }

        // Cleanup is requested after the import, never before it: the importer
        // refuses a batch that is not stored and published, so the ordering rule
        // holds even if this call is reached too early.
        let cleanup = await requestCleanup(for: outcome.save?.batchID, mode: attemptCleanupMode)

        guard self.generation == generation else { return }
        settle()

        let presented = PenReadOutcome(
            summary: read.summary,
            save: outcome.save,
            export: outcome.export,
            cleanup: cleanup,
            destinationDirectory: directory,
            penState: read.penState
        )
        phase = .complete(presented)
    }

    /// Requests cleanup for a stored batch, or explains why there is none.
    ///
    /// The mode is the intent of the step that asks: the running attempt's for a
    /// read, and the shell's current choice for a retry. It is never read from the
    /// policy here, so the intent the shell shows is the intent that is used.
    ///
    /// A cleanup problem never discards a completed save: the pen's copy is
    /// reported as skipped instead, and the library copy is unaffected.
    private func requestCleanup(for batchID: UUID?, mode: PenCleanupMode) async -> PenCleanupOutcome {
        guard let batchID else {
            return .skipped(reason: "the read stored no strokes, so there is nothing to reclaim")
        }

        // No sender is supplied: the deletion command has no evidence-backed
        // payload framing yet, so the app opens no link for it and the importer
        // reports cleanup as skipped rather than sending a guessed frame. The
        // evidence gate refuses the command before the sender is ever consulted.
        let request = PenCleanupRequest(mode: mode, sender: nil)
        do {
            return try await library.requestCleanup(batchID, request: request)
        } catch {
            return .skipped(reason: penSyncErrorMessage(for: error))
        }
    }

    /// Ends the attempt, leaving the read's own intent in place.
    ///
    /// The read's intent stays available so the shell keeps showing what it used and
    /// so a retry of that read can still be given a different choice; the next read's
    /// intent is independent of it.
    private func settle() {
        attempt = nil
    }

    // MARK: - Attempt updates

    private func apply(_ stage: PenSyncStage, for generation: Int) {
        guard self.generation == generation else { return }
        phase = Phase(stage)
    }

    private func apply(_ stage: PenImportStage, for generation: Int) {
        guard self.generation == generation else { return }
        switch stage {
        case .saving: phase = .saving
        case .exporting: phase = .exporting
        }
    }

    private func finishRetry(
        with report: PenExportReport,
        cleanup: PenCleanupOutcome,
        for generation: Int,
        base outcome: PenReadOutcome
    ) {
        guard self.generation == generation else { return }
        settle()

        let updated = PenReadOutcome(
            summary: outcome.summary,
            save: outcome.save,
            export: report,
            cleanup: cleanup,
            destinationDirectory: outcome.destinationDirectory,
            penState: outcome.penState
        )
        phase = .complete(updated)
    }

    private func fail(with error: any Error, for generation: Int) {
        guard self.generation == generation else { return }

        // Several matching pens is a question, not a failure: no pen is picked
        // silently, so the user answers it. No read has run yet, so the start that
        // asked the question consumed nothing: the intent it captured is handed
        // back to the shell, and the pen the user chooses uses it.
        if let bluetoothError = error as? PenBluetoothError,
            case .multiplePensFound(_, let candidates) = bluetoothError
        {
            attempt = nil
            nextReadCleanupMode = attemptCleanupMode
            phase = .choosingPen(candidates: candidates)
            return
        }

        settle()

        phase = .failed(
            message: penSyncErrorMessage(for: error),
            diagnostic: penSyncErrorDiagnostic(for: error)
        )
    }
}

extension PenSyncController.Phase {
    /// Maps a stage to the phase that presents it.
    public init(_ stage: PenSyncStage) {
        switch stage {
        case .scanning: self = .scanning
        case .connecting: self = .connecting
        case .verifying: self = .verifying
        case .syncing: self = .syncing
        }
    }
}
