import Foundation
import NeoProtocol
import Synchronization

/// Adapts a CoreBluetooth central to the portable `PenTransport` contract.
///
/// The transport owns the platform-specific half of a pen connection: it scans,
/// selects a peripheral by advertised name, connects, and routes outbound frames
/// to the write characteristic. Everything after the connection — the handshake,
/// the version gate, discovery, and assembly — belongs to `PenSession`, which
/// sees only bytes.
///
/// The connection is established by an explicit `connect()` call rather than by
/// the first `receive()`, because `PenTransport.receive()` cannot report an
/// error and the shell has to show one before the handshake can begin.
public final class CoreBluetoothPenTransport: PenTransport, Sendable {
    /// The name an A1 advertises.
    ///
    /// The pen advertises a random static address that changes across power
    /// cycles, so the name is the only usable match key. The address is never
    /// read, stored, or shown.
    public static let advertisedName = "Neosmartpen_A1"

    /// How long to wait for the adapter state to become known before scanning.
    ///
    /// CoreBluetooth reports `.unknown` until it has read the radio, which takes
    /// a moment after the manager is created. Refusing to scan during that window
    /// would fail a read the user just asked for, so the state is polled for this
    /// long and reported only if it never resolves.
    public static let defaultAdapterStateGrace: Duration = .seconds(2)

    /// How long the scan runs at most before deciding that no pen is present.
    ///
    /// The physical A1 advertises in bursts, and it can be silent for a while after
    /// it is switched on. Measured on 2026-10-19: while awake it produced about one
    /// advertisement per second, the first advertisement after a scan started
    /// arrived as late as 2.5 seconds in, and the longest gap between two
    /// advertisements was 3.9 seconds. The delay after a switch-on was not
    /// consistent: once the pen was still invisible 6 seconds after it had been
    /// switched on, which is when a read reported "no pen found" with the pen
    /// standing right there, and once it advertised within about 3 seconds of the
    /// scan starting.
    ///
    /// This window is therefore sized for the slower of those two observed cases,
    /// not for the awake case. It costs nothing in the common case, because one
    /// match settles the scan after `defaultAmbiguityConfirmation` rather than
    /// waiting it out; the full window is paid only when no pen is advertising at
    /// all, and Cancel Read ends even that. Do not read "no pen found" as proof
    /// that the pen is absent until the window has elapsed.
    public static let defaultSelectionWindow: Duration = .seconds(30)

    /// How long the scan keeps running after the first match.
    ///
    /// The window exists to notice a second pen, not to slow down the common
    /// case, so a single matched pen settles the scan after this long instead of
    /// waiting out the whole maximum. A second pen advertises on the same
    /// cadence, so one second is long enough to see it.
    public static let defaultAmbiguityConfirmation: Duration = .seconds(1)

    /// How the transport picks a pen when a scan reports more than one match.
    public enum Selection: Hashable, Sendable {
        /// Accept the only match the scan window reported.
        case automatic

        /// Use the peripheral the user chose from a previous scan.
        case explicit(PenPeripheral)
    }

    private struct State: Sendable {
        var connection: (any PenBluetoothConnection)?
    }

    private let central: any PenBluetoothCentral
    private let advertisedName: String
    private let selection: Selection
    private let selectionWindow: Duration
    private let ambiguityConfirmation: Duration
    private let adapterStateGrace: Duration
    private let state = Mutex(State())

    /// Creates a transport over a Bluetooth central.
    ///
    /// - Parameters:
    ///   - central: The CoreBluetooth operations to use. A test injects a fake.
    ///   - advertisedName: The name to match. Defaults to the A1's name.
    ///   - selection: The selection policy for the scan.
    ///   - selectionWindow: How long to collect matches at most before deciding,
    ///     so a second pen in range produces an explicit-choice error instead of a
    ///     silent pick.
    ///   - ambiguityConfirmation: How long to keep scanning after the first
    ///     match, so a second pen still has its chance to appear before the scan
    ///     settles on the first one.
    ///   - adapterStateGrace: How long to wait for an unresolved adapter state
    ///     before reporting it.
    public init(
        central: any PenBluetoothCentral,
        advertisedName: String = CoreBluetoothPenTransport.advertisedName,
        selection: Selection = .automatic,
        selectionWindow: Duration = CoreBluetoothPenTransport.defaultSelectionWindow,
        ambiguityConfirmation: Duration = CoreBluetoothPenTransport.defaultAmbiguityConfirmation,
        adapterStateGrace: Duration = CoreBluetoothPenTransport.defaultAdapterStateGrace
    ) {
        self.central = central
        self.advertisedName = advertisedName
        self.selection = selection
        self.selectionWindow = selectionWindow
        self.ambiguityConfirmation = ambiguityConfirmation
        self.adapterStateGrace = adapterStateGrace
    }

    /// Whether a connection is established.
    public var isConnected: Bool {
        state.withLock { $0.connection != nil }
    }

    /// Scans, selects a pen, and connects.
    ///
    /// - Returns: The peripheral the transport connected to.
    /// - Throws: `PenBluetoothError` for a denied permission, an unavailable
    ///   adapter, a missing or ambiguous pen, or a failed channel setup.
    @discardableResult
    public func connect() async throws -> PenPeripheral {
        // Permission and adapter state are checked before the scan, so a denied
        // request never turns on the radio.
        let adapterState = try await awaitResolvedAdapterState()
        if let error = adapterState.unavailableError {
            throw error
        }

        let peripheral = try await selectPen()

        let connection: any PenBluetoothConnection
        do {
            connection = try await central.connect(to: peripheral)
        } catch let error as PenBluetoothError {
            throw error
        } catch {
            throw PenBluetoothError.connectionFailed(description: String(describing: error))
        }

        state.withLock { $0.connection = connection }
        return peripheral
    }

    // MARK: - PenTransport

    public func receive() -> AsyncThrowingStream<[UInt8], any Error> {
        guard let connection = state.withLock({ $0.connection }) else {
            return AsyncThrowingStream { $0.finish(throwing: PenBluetoothError.notConnected) }
        }
        return connection.receive()
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard let connection = state.withLock({ $0.connection }) else {
            throw PenBluetoothError.notConnected
        }

        // The SDK slices a frame into 20-byte writes because the ATT payload is
        // smaller than a framed request, so the pen reassembles the frame from
        // its marker bytes. Each slice is awaited, so the writes stay in order.
        for slice in Self.writes(for: bytes) {
            try await connection.write(slice)
        }
    }

    public func close() async {
        let connection = state.withLock { state -> (any PenBluetoothConnection)? in
            defer { state.connection = nil }
            return state.connection
        }
        await connection?.close()
    }

    // MARK: - Selection

    /// The adapter state once it has resolved, or `.unknown`/`.resetting` when it
    /// never does within the grace window.
    ///
    /// CoreBluetooth reports `.unknown` until it has read the radio, so a read
    /// started immediately after the app launches would otherwise fail with
    /// "the Bluetooth state is not known yet" instead of scanning. Polling is what
    /// the state property allows; the grace window keeps the wait bounded.
    private func awaitResolvedAdapterState() async throws -> PenBluetoothState {
        var state = central.state
        guard state == .unknown || state == .resetting else { return state }

        let deadline = ContinuousClock.now + adapterStateGrace
        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                throw PenBluetoothError.cancelled
            }
            state = central.state
            if state != .unknown, state != .resetting { break }
        }
        return state
    }

    /// Picks the pen to connect to.
    private func selectPen() async throws -> PenPeripheral {
        if case .explicit(let chosen) = selection {
            // The user already answered the question, so no second scan runs.
            return chosen
        }

        let matches = try await matchesInScanWindow()
        switch matches.count {
        case 0:
            // A scan that found nothing means "no pen" only while the adapter is
            // still ready. A scan interrupted by the adapter going away ends with
            // an error that contributes no match, so the adapter state is what
            // tells the two apart — otherwise switching Bluetooth off mid-scan
            // would be reported as a missing pen.
            if let error = central.state.unavailableError {
                throw error
            }
            throw PenBluetoothError.noMatchingPenFound(advertisedName: advertisedName)
        case 1:
            return matches[0]
        default:
            throw PenBluetoothError.multiplePensFound(
                advertisedName: advertisedName,
                candidates: matches
            )
        }
    }

    /// Collects the distinct matches the scan window reports.
    ///
    /// The window ends when `selectionWindow` elapses, or sooner once a pen is
    /// known and a second one has had `ambiguityConfirmation` to appear. Waiting
    /// the full maximum for every read would add seconds to the common case,
    /// while ending on the first match could not tell one pen from two. The
    /// physical A1 advertises in bursts, so the maximum is what makes the scan
    /// reliable; the confirmation is what keeps it quick.
    private func matchesInScanWindow() async throws -> [PenPeripheral] {
        let stream = central.scan()
        let found = MatchCounter()
        let collector = Task { () -> [PenPeripheral] in
            var collected: [PenPeripheral] = []
            var seen = Set<UUID>()
            do {
                for try await peripheral in stream where peripheral.name == advertisedName {
                    guard seen.insert(peripheral.id).inserted else { continue }
                    collected.append(peripheral)
                    found.recordOne()
                }
            } catch {
                // An interrupted scan contributes no further match. The caller
                // decides what that means: an adapter error when the adapter is
                // no longer ready, a missing pen otherwise.
            }
            return collected
        }

        let deadline = ContinuousClock.now + selectionWindow
        var confirmedUntil: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                throw await cancelScan(collector)
            }
            // A cancellation that arrives outside the sleep still has to end the
            // scan and report itself, rather than settle the window as if it had
            // run out.
            if Task.isCancelled {
                throw await cancelScan(collector)
            }

            let count = found.matchCount
            guard count > 0 else { continue }
            // Two pens answer the question by themselves; one needs the
            // confirmation to elapse before it is safe to settle on it.
            if count > 1 { break }
            if confirmedUntil == nil { confirmedUntil = ContinuousClock.now + ambiguityConfirmation }
            if let confirmedUntil, ContinuousClock.now >= confirmedUntil { break }
        }

        // Stopping the scan finishes the stream, so the collector settles with
        // every match the window saw.
        await central.stopScan()
        return await collector.value
    }

    /// Ends the scan because the caller cancelled, and reports it.
    private func cancelScan(_ collector: Task<[PenPeripheral], Never>) async -> PenBluetoothError {
        collector.cancel()
        await central.stopScan()
        return .cancelled
    }

    /// Splits a frame into the ordered writes the write characteristic accepts.
    private static func writes(for bytes: [UInt8]) -> [[UInt8]] {
        guard !bytes.isEmpty else { return [] }
        let unit = PenGATT.maximumTransmissionUnit
        guard unit > 0, bytes.count > unit else { return [bytes] }
        return stride(from: 0, to: bytes.count, by: unit).map { start in
            Array(bytes[start..<min(start + unit, bytes.count)])
        }
    }
}

/// How many distinct pens the scan collector has reported so far.
///
/// The collector task reports and the window loop polls, so the two share one
/// counter. It is a class rather than a bare `Mutex` because the collector is an
/// escaping closure, and a mutex cannot be captured that way.
private final class MatchCounter: @unchecked Sendable {
    private let count = Mutex(0)

    /// How many distinct pens have been reported.
    var matchCount: Int { count.withLock { $0 } }

    /// Records one distinct pen.
    func recordOne() {
        count.withLock { $0 += 1 }
    }
}
