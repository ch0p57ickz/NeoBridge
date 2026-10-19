import Foundation
import NeoCore
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

    /// What the shell is showing now.
    public private(set) var phase: Phase = .idle

    private let runners: PenSyncRunnerFactory
    private let library: any PenImportCoordinator
    private let destination: any PenExportDestinationProviding
    private var attempt: Task<Void, Never>?
    private var generation = 0

    /// Creates a controller.
    ///
    /// - Parameters:
    ///   - runners: The factory that makes a runner for each attempt.
    ///   - library: The verified importer that stores a read and publishes it.
    ///   - destination: The folder exports are written to.
    public init(
        runners: PenSyncRunnerFactory,
        library: any PenImportCoordinator,
        destination: any PenExportDestinationProviding
    ) {
        self.runners = runners
        self.library = library
        self.destination = destination
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
        attempt = nil
        generation += 1
        phase = .idle
    }

    /// Publishes the last stored read's files again.
    ///
    /// The retry reads the committed rows, so it never imports the read twice and
    /// never invents a result from data that was not stored.
    public func retryExport() {
        guard canRetryExport, case .complete(let outcome) = phase, let save = outcome.save,
            let directory = outcome.destinationDirectory
        else { return }

        generation += 1
        let generation = self.generation
        phase = .exporting

        let request = PenExportRequest(pages: save.pages, destinationDirectory: directory)
        attempt = Task { [weak self] in
            guard let controller = self else { return }
            do {
                let report = try await controller.library.retryExport(
                    batchID: save.batchID,
                    request: request
                )
                controller.finishRetry(with: report, for: generation, base: outcome)
            } catch {
                controller.fail(with: error, for: generation)
            }
        }
    }

    // MARK: - Attempt

    private func start(selection: CoreBluetoothPenTransport.Selection) {
        guard !isBusy else { return }

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

    /// Commits the read and publishes its files.
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
        attempt = nil

        let presented = PenReadOutcome(
            summary: read.summary,
            save: outcome.save,
            export: outcome.export,
            destinationDirectory: directory
        )
        phase = .complete(presented)
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
        for generation: Int,
        base outcome: PenReadOutcome
    ) {
        guard self.generation == generation else { return }
        attempt = nil

        let updated = PenReadOutcome(
            summary: outcome.summary,
            save: outcome.save,
            export: report,
            destinationDirectory: outcome.destinationDirectory
        )
        phase = .complete(updated)
    }

    private func fail(with error: any Error, for generation: Int) {
        guard self.generation == generation else { return }
        attempt = nil

        // Several matching pens is a question, not a failure: no pen is picked
        // silently, so the user answers it.
        if let bluetoothError = error as? PenBluetoothError,
            case .multiplePensFound(_, let candidates) = bluetoothError
        {
            phase = .choosingPen(candidates: candidates)
            return
        }

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
