import Foundation
import Observation

/// Drives one read attempt and publishes what the shell shows.
///
/// The controller owns the attempt lifecycle — start, cancel, retry — and no
/// protocol or Bluetooth logic. It reads one runner per attempt from its
/// factory, so every retry starts a new scan and a new session.
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

        /// Several pens advertised the expected name, so the user chooses one.
        ///
        /// No pen is picked silently, and no candidate carries an address.
        case choosingPen(candidates: [PenPeripheral])

        /// Every discovered note was read.
        case complete(PenSyncSummary)

        /// A step failed. `diagnostic` describes partial data when a transfer
        /// stopped early, and is never presented as a completed sync.
        case failed(message: String, diagnostic: String?)

        /// Whether the attempt has stopped and will do no more work.
        public var isTerminal: Bool {
            switch self {
            case .complete, .failed: return true
            case .idle, .scanning, .connecting, .verifying, .syncing, .choosingPen: return false
            }
        }
    }

    /// The title of the action that retrieves offline strokes.
    ///
    /// The label says the app reads the pen, because this version neither
    /// imports into a library nor exports a file.
    public static let readActionTitle = "Read Pen Data"

    /// The notice shown with a completed result.
    public static let notSavedNotice =
        "These results are held in memory only. Nothing was written to disk or exported."

    /// What the shell is showing now.
    public private(set) var phase: Phase = .idle

    private let runners: PenSyncRunnerFactory
    private var attempt: Task<Void, Never>?
    private var generation = 0

    /// Creates a controller.
    ///
    /// - Parameter runners: The factory that makes a runner for each attempt.
    public init(runners: PenSyncRunnerFactory) {
        self.runners = runners
    }

    /// Whether an attempt is running.
    public var isBusy: Bool {
        switch phase {
        case .scanning, .connecting, .verifying, .syncing: return true
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
        case .choosingPen: return "Choose a pen"
        case .complete: return "Complete"
        case .failed: return "Failed"
        }
    }

    /// The completed result, when the attempt succeeded.
    public var result: PenSyncSummary? {
        if case .complete(let result) = phase { return result }
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
            let report: @Sendable (PenSyncStage) -> Void = { stage in
                Task { @MainActor in
                    controller.apply(stage, for: generation)
                }
            }

            do {
                let result = try await runner.run(report: report)
                controller.complete(with: result, for: generation)
            } catch {
                controller.fail(with: error, for: generation)
            }
        }
    }

    // MARK: - Attempt updates

    private func apply(_ stage: PenSyncStage, for generation: Int) {
        guard self.generation == generation else { return }
        phase = Phase(stage)
    }

    private func complete(with result: PenSyncSummary, for generation: Int) {
        guard self.generation == generation else { return }
        attempt = nil
        phase = .complete(result)
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
