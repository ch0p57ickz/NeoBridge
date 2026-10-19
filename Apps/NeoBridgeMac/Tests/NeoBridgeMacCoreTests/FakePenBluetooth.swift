import Foundation
import NeoBridgeMacCore
import Synchronization

/// A scripted stand-in for the Bluetooth adapter.
///
/// The transport's selection and routing rules run against this fake, so no test
/// needs a radio. The scan stream stays open until `stopScan()`, which is the
/// contract ``CoreBluetoothPenTransport`` relies on to collect every match
/// before it decides.
final class FakePenBluetoothCentral: PenBluetoothCentral, @unchecked Sendable {
    private struct Store {
        var isScanning = false
        var didStopScan = false
        var scanContinuation: AsyncThrowingStream<PenPeripheral, any Error>.Continuation?
        var connected: [PenPeripheral] = []
        var state: PenBluetoothState = .poweredOn
    }

    /// The peripherals a scan reports, in order.
    let advertisedPeripherals: [PenPeripheral]

    /// The state the adapter reports once it has resolved.
    let adapterState: PenBluetoothState

    /// An error the scan finishes with. When absent, the scan stays open until
    /// `stopScan()`.
    let scanFailure: PenBluetoothError?

    /// A state the adapter adopts when the scan stops, which models the adapter
    /// going away while a scan was running. The scan then also finishes with the
    /// matching adapter error, because on hardware the state change and the scan
    /// failure arrive together.
    let stateAfterScan: PenBluetoothState?

    /// How long the adapter reports `.unknown` before its real state resolves.
    ///
    /// CoreBluetooth reports `.unknown` until it has read the radio, and a read
    /// started immediately after launch lands in that window. This delay models
    /// it, so the transport's bounded wait can be tested without a radio.
    let adapterStateResolvesAfter: Duration?

    /// When the adapter stops reporting `.unknown`.
    private let adapterStateResolvesAt: Date?

    /// An error `connect(to:)` throws instead of returning a channel.
    let connectionFailure: PenBluetoothError?

    /// When `true`, `connect(to:)` does not return until the caller cancels,
    /// which models a CoreBluetooth callback that never arrives.
    let connectionStalls: Bool

    /// How long after `scan()` starts each advertisement arrives.
    ///
    /// The physical pen advertises in bursts, so its first advertisement can
    /// arrive seconds after a scan starts. This delay models that silence.
    let advertisementDelay: Duration?

    /// The channel `connect(to:)` returns.
    let connection: FakePenBluetoothConnection

    private let store = Mutex(Store())

    init(
        adapterState: PenBluetoothState = .poweredOn,
        adapterStateResolvesAfter: Duration? = nil,
        advertisedPeripherals: [PenPeripheral] = [],
        scanFailure: PenBluetoothError? = nil,
        stateAfterScan: PenBluetoothState? = nil,
        connectionFailure: PenBluetoothError? = nil,
        connectionStalls: Bool = false,
        advertisementDelay: Duration? = nil,
        connection: FakePenBluetoothConnection = FakePenBluetoothConnection()
    ) {
        self.adapterState = adapterState
        self.adapterStateResolvesAfter = adapterStateResolvesAfter
        self.adapterStateResolvesAt = adapterStateResolvesAfter.map {
            Date().addingTimeInterval(Self.seconds($0))
        }
        self.advertisedPeripherals = advertisedPeripherals
        self.scanFailure = scanFailure
        self.stateAfterScan = stateAfterScan
        self.connectionFailure = connectionFailure
        self.connectionStalls = connectionStalls
        self.advertisementDelay = advertisementDelay
        self.connection = connection
        store.withLock { $0.state = adapterState }
    }

    /// Whether `scan()` has been called.
    var didScan: Bool { store.withLock { $0.isScanning } }

    /// Whether `stopScan()` has been called.
    var didStopScan: Bool { store.withLock { $0.didStopScan } }

    /// Every peripheral passed to `connect(to:)`, in order.
    var connectedPeripherals: [PenPeripheral] { store.withLock { $0.connected } }

    // MARK: - PenBluetoothCentral

    var state: PenBluetoothState {
        // The unresolved window comes first: it is the state CoreBluetooth
        // reports between the manager's creation and its first read.
        if let resolvesAt = adapterStateResolvesAt, Date() < resolvesAt { return .unknown }
        return store.withLock { $0.state }
    }

    func scan() -> AsyncThrowingStream<PenPeripheral, any Error> {
        let advertised = advertisedPeripherals
        let failure = scanFailure
        let delay = advertisementDelay

        return AsyncThrowingStream { continuation in
            store.withLock { store in
                store.isScanning = true
                store.scanContinuation = continuation
            }

            let deliver = {
                for peripheral in advertised {
                    continuation.yield(peripheral)
                }
                if let failure {
                    continuation.finish(throwing: failure)
                }
            }

            guard let delay else {
                deliver()
                return
            }
            // A pen that advertises late arrives after the scan has been running,
            // so the advertisements are delivered from a task.
            Task {
                try? await Task.sleep(for: delay)
                deliver()
            }
        }
    }

    func stopScan() async {
        let continuation = store.withLock {
            store -> AsyncThrowingStream<PenPeripheral, any Error>.Continuation? in
            store.didStopScan = true
            if let stateAfterScan {
                store.state = stateAfterScan
            }
            defer { store.scanContinuation = nil }
            return store.scanContinuation
        }
        // On hardware, an adapter that stops being ready ends the scan with an
        // error as well as changing state, so both halves are modelled here.
        if let stateAfterScan, let error = stateAfterScan.unavailableError {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    func connect(to peripheral: PenPeripheral) async throws -> any PenBluetoothConnection {
        store.withLock { $0.connected.append(peripheral) }
        if connectionStalls {
            // Waits for cancellation, which is what a CoreBluetooth callback that
            // never arrives looks like.
            try await Task.sleep(for: .seconds(3600))
        }
        if let connectionFailure {
            throw connectionFailure
        }
        return connection
    }

    /// A duration in seconds, for the fake's wall-clock comparisons.
    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}

/// A scripted stand-in for one pen's byte channel.
final class FakePenBluetoothConnection: PenBluetoothConnection, @unchecked Sendable {
    private struct Store {
        var writes: [[UInt8]] = []
        var isClosed = false
        var continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation?
    }

    private let store = Mutex(Store())
    private let inbound: [[UInt8]]
    private let inboundFailure: PenBluetoothError?
    private let endsAfterScript: Bool

    /// Creates a channel.
    ///
    /// - Parameters:
    ///   - inbound: The chunks the channel delivers when it is created.
    ///   - inboundFailure: An error to throw after the chunks.
    ///   - endsAfterScript: Whether the scripted chunks end the stream. Set it to
    ///     `false` when a test delivers chunks later with `emit(_:)`, because a
    ///     finished stream ignores further chunks.
    init(
        inbound: [[UInt8]] = [],
        inboundFailure: PenBluetoothError? = nil,
        endsAfterScript: Bool = true
    ) {
        self.inbound = inbound
        self.inboundFailure = inboundFailure
        self.endsAfterScript = endsAfterScript
    }

    /// Every chunk passed to `write(_:)`, in order.
    var writes: [[UInt8]] { store.withLock { $0.writes } }

    /// Every byte passed to `write(_:)`, concatenated.
    var writtenBytes: [UInt8] { writes.flatMap { $0 } }

    /// Whether `close()` has been called.
    var isClosed: Bool { store.withLock { $0.isClosed } }

    // MARK: - PenBluetoothConnection

    func receive() -> AsyncThrowingStream<[UInt8], any Error> {
        let chunks = inbound
        let failure = inboundFailure
        let endsAfterScript = self.endsAfterScript

        return AsyncThrowingStream { continuation in
            store.withLock { $0.continuation = continuation }
            for chunk in chunks {
                continuation.yield(chunk)
            }
            guard endsAfterScript else { return }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        store.withLock { $0.writes.append(bytes) }
    }

    func close() async {
        store.withLock { $0.isClosed = true }
    }

    // MARK: - Script control

    /// Delivers one chunk, as a notification would.
    func emit(_ bytes: [UInt8]) {
        store.withLock { $0.continuation }?.yield(bytes)
    }

    /// Ends the stream without error, as a clean disconnect would.
    func finishNormally() {
        let continuation = store.withLock {
            store -> AsyncThrowingStream<[UInt8], any Error>.Continuation? in
            defer { store.continuation = nil }
            return store.continuation
        }
        continuation?.finish()
    }

    /// Ends the stream with an error, as an interruption would.
    func finish(throwing error: any Error) {
        let continuation = store.withLock {
            store -> AsyncThrowingStream<[UInt8], any Error>.Continuation? in
            defer { store.continuation = nil }
            return store.continuation
        }
        continuation?.finish(throwing: error)
    }
}
