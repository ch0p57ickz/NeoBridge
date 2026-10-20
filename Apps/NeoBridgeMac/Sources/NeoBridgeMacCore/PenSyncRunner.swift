import Foundation
import NeoCore
import NeoProtocol
import NeoStorage

/// One stage of a read attempt, in the order a successful attempt reports them.
///
/// `PenSessionState` starts at the version handshake, because that is where the
/// portable session begins. Scanning and the Bluetooth connection are the host's
/// work, so this type adds them and the session reports the rest.
public enum PenSyncStage: Hashable, Sendable {
    /// Scanning for a pen that advertises the expected name.
    case scanning

    /// Sending `0x01` and awaiting the version response.
    case connecting

    /// Checking the reported protocol version.
    case verifying

    /// Discovering notes and reading their offline data.
    case syncing

    /// A short label for the status row.
    public var label: String {
        switch self {
        case .scanning: return "Scanning for a pen"
        case .connecting: return "Connecting to the pen"
        case .verifying: return "Verifying the pen"
        case .syncing: return "Reading pen data"
        }
    }
}

extension PenSyncStage {
    /// Maps a session state to a stage, or `nil` for a terminal state.
    init?(_ state: PenSessionState) {
        switch state {
        case .connecting: self = .connecting
        case .verifying: self = .verifying
        case .syncing: self = .syncing
        case .idle, .complete, .failed: return nil
        }
    }
}

/// One attempt at reading a pen's offline data.
///
/// The app depends on this protocol rather than on `PenSession` so a test can
/// drive the shell through every stage and every failure without a radio.
public protocol PenSyncRunning: Sendable {
    /// Scans, connects, and reads.
    ///
    /// - Parameter report: Called as each stage begins. The callbacks arrive in
    ///   stage order from the session's sequential transitions.
    /// - Returns: The summary the shell presents and the complete transfer the
    ///   library commits.
    /// - Throws: A `PenBluetoothError` or `PenSessionError` describing the
    ///   failed step.
    func run(report: @escaping @Sendable (PenSyncStage) -> Void) async throws -> PenReadResult
}

/// Makes a fresh runner for each attempt.
///
/// A retry needs a new transport as well as a new session, because a
/// `PenSession` is one attempt: it resets its decoder and assembler only by
/// being replaced.
public struct PenSyncRunnerFactory: Sendable {
    private let make: @Sendable (CoreBluetoothPenTransport.Selection) -> any PenSyncRunning

    /// Creates a factory.
    public init(make: @escaping @Sendable (CoreBluetoothPenTransport.Selection) -> any PenSyncRunning) {
        self.make = make
    }

    /// Creates a runner for one attempt.
    ///
    /// - Parameter selection: How the attempt picks a pen. An attempt that found
    ///   several matches is repeated with the user's `.explicit` choice.
    public func makeRunner(
        selection: CoreBluetoothPenTransport.Selection = .automatic
    ) -> any PenSyncRunning {
        make(selection)
    }
}

/// Reads a pen over CoreBluetooth.
///
/// The runner is the only place that knows both halves: it connects the
/// Bluetooth transport, then hands it to the portable session. Everything the
/// session needs is bytes.
public struct BluetoothPenSyncRunner: PenSyncRunning {
    private let central: any PenBluetoothCentral
    private let advertisedName: String
    private let selection: CoreBluetoothPenTransport.Selection
    private let selectionWindow: Duration
    private let ambiguityConfirmation: Duration
    private let setupTimeout: Duration
    private let timeouts: PenSessionTimeouts
    private let transferOption: OfflineReadTransferOption
    private let abortAtPacket: Int?
    private let trace: PenTrafficLog?

    /// How much time the setup phase gets beyond the scan window.
    ///
    /// The deadline covers the scan window, the connection, the service and
    /// characteristic discovery, and the notification subscription. Those steps
    /// after the scan are fast on hardware, so the allowance is mostly margin.
    public static let setupAllowance: Duration = .seconds(25)

    /// The setup deadline for a scan window.
    ///
    /// The deadline has to outlast the window: a setup that gives up first would
    /// report a setup timeout for a read that was still scanning, which is the
    /// same "no pen found" complaint in different words. Deriving it from the
    /// window keeps the two from drifting apart.
    public static func setupDeadline(for window: Duration) -> Duration {
        window + setupAllowance
    }

    /// Creates a runner for one attempt.
    ///
    /// - Parameters:
    ///   - central: The Bluetooth adapter to connect with.
    ///   - advertisedName: The pen's advertised name.
    ///   - selection: The selection policy for the scan.
    ///   - selectionWindow: How long to collect scan matches at most before
    ///     deciding. It defaults to the transport's window, which is sized for
    ///     the A1's bursty advertising rather than for a pen that answers
    ///     instantly.
    ///   - ambiguityConfirmation: How long the scan keeps running after the first
    ///     match, so a second pen still has its chance to appear.
    ///   - setupTimeout: The bound on the Bluetooth setup phase as a whole. When
    ///     omitted it is derived from the scan window, because CoreBluetooth has
    ///     no timeout of its own and a callback that never arrives would
    ///     otherwise leave a read attempt waiting with no way out but Cancel Read.
    ///   - timeouts: The bounded waits the session applies.
    ///   - transferOption: The `0x23` transfer option the session sends. It
    ///     defaults to the established non-destructive option; the acceptance run
    ///     varies it while the incremental-transfer experiment runs.
    ///   - abortAtPacket: When set, the attempt drops the link as that `0x24`
    ///     packet arrives, so the transfer fails part way on purpose. Only the
    ///     acceptance run sets it.
    ///   - trace: An optional transcript of the attempt's traffic. An acceptance
    ///     run supplies one so the framed bytes the host sent can be checked.
    public init(
        central: any PenBluetoothCentral,
        advertisedName: String = CoreBluetoothPenTransport.advertisedName,
        selection: CoreBluetoothPenTransport.Selection = .automatic,
        selectionWindow: Duration = CoreBluetoothPenTransport.defaultSelectionWindow,
        ambiguityConfirmation: Duration = CoreBluetoothPenTransport.defaultAmbiguityConfirmation,
        setupTimeout: Duration? = nil,
        timeouts: PenSessionTimeouts = .default,
        transferOption: OfflineReadTransferOption = .nextAndReserve,
        abortAtPacket: Int? = nil,
        trace: PenTrafficLog? = nil
    ) {
        self.central = central
        self.advertisedName = advertisedName
        self.selection = selection
        self.selectionWindow = selectionWindow
        self.ambiguityConfirmation = ambiguityConfirmation
        self.setupTimeout = setupTimeout ?? Self.setupDeadline(for: selectionWindow)
        self.timeouts = timeouts
        self.transferOption = transferOption
        self.abortAtPacket = abortAtPacket
        self.trace = trace
    }

    public func run(
        report: @escaping @Sendable (PenSyncStage) -> Void
    ) async throws -> PenReadResult {
        let base = CoreBluetoothPenTransport(
            central: central,
            advertisedName: advertisedName,
            selection: selection,
            selectionWindow: selectionWindow,
            ambiguityConfirmation: ambiguityConfirmation
        )
        // The abort sits under the transcript, so the transcript records the chunks
        // the session actually received: the packet whose arrival drops the link is
        // never one of them.
        let delivered: any PenTransport = abortAtPacket.map {
            PenAbortingTransport(wrapping: base, abortAtPacket: $0, log: trace)
        } ?? base
        let transport: any PenTransport = trace.map {
            PenTracingTransport(wrapping: delivered, log: $0)
        } ?? delivered

        report(.scanning)
        trace?.recordState(PenSyncStage.scanning.label)
        do {
            try await withSetupDeadline { _ = try await base.connect() }
        } catch {
            trace?.recordFailure(error)
            await transport.close()
            throw error
        }

        // The session takes over once the transport exists. It reports the
        // remaining stages and closes the transport on failure.
        let session = PenSession(
            transport: transport,
            timeouts: timeouts,
            transferOption: transferOption,
            queryPenState: true,
            onStateChange: { state in
                trace?.recordState(state.label)
                guard let stage = PenSyncStage(state) else { return }
                report(stage)
            }
        )

        do {
            let result = try await session.run()
            // The attempt owns the link from the moment it connects, so it also
            // releases it on success. A connected pen stops advertising, so a
            // reader that kept the link would make its own next read report "no
            // pen found" and would keep the pen from its other owners. Nothing is
            // deleted from the pen by disconnecting: the read path can only send a
            // non-destructive transfer option, so the strokes stay on it.
            await transport.close()
            trace?.recordState("Disconnected")
            trace?.recordCompletion(result)
            // The complete transfer travels with the display summary, so the
            // read can be stored rather than reduced to counts.
            return PenReadResult(result)
        } catch {
            trace?.recordFailure(error)
            throw error
        }
    }

    /// Races the Bluetooth setup phase against its deadline.
    ///
    /// The transport's setup is cancellation driven: `PenTransport.connect()` and
    /// the transport's own `close()` both release the CoreBluetooth waits, so the
    /// losing branch of the race finishes rather than stalling the group.
    private func withSetupDeadline(
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let timeout = setupTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PenBluetoothError.setupTimedOut(
                    description: "the pen did not answer within \(timeout)"
                )
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

// MARK: - Error presentation

/// A message for any error the Bluetooth layer, the session, or the library can
/// raise.
///
/// The shell shows error strings, and every layer already phrases its errors for a
/// reader, so this only decides which layer's phrasing to use.
public func penSyncErrorMessage(for error: any Error) -> String {
    switch error {
    case let bluetoothError as PenBluetoothError:
        return bluetoothError.message
    case let sessionError as PenSessionError:
        return sessionError.message
    case let storageError as StorageError:
        return storageError.message
    case is CancellationError:
        return PenSessionError.cancelled.message
    default:
        return String(describing: error)
    }
}

/// Diagnostic detail for a failure that arrived after some packets, or `nil`.
///
/// This text describes what a failed transfer managed to read. It is never
/// presented as a completed sync, so partial counts stay diagnostic.
public func penSyncErrorDiagnostic(for error: any Error) -> String? {
    guard let sessionError = error as? PenSessionError,
        case .incompleteTransfer(let packetCount) = sessionError
    else { return nil }
    return "\(packetCount) packet\(packetCount == 1 ? "" : "s") arrived before the pen stopped sending."
}
