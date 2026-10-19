import Foundation

/// The states the Bluetooth adapter reports.
///
/// The cases mirror `CBManagerState`, but the type is a plain value so the
/// transport can be tested without a radio.
public enum PenBluetoothState: Hashable, Sendable {
    /// The adapter state is not known yet.
    case unknown

    /// The system is resetting the adapter.
    case resetting

    /// This Mac has no Bluetooth LE adapter.
    case unsupported

    /// The user has not granted Bluetooth access.
    case unauthorized

    /// Bluetooth is switched off.
    case poweredOff

    /// The adapter can scan and connect.
    case poweredOn

    /// Whether the adapter is ready to scan.
    public var isReady: Bool { self == .poweredOn }

    /// The error to report when the adapter is not ready, or `nil` when it is.
    ///
    /// A denied permission is reported as its own error, because the shell adds a
    /// different remedy for it. Every other not-ready state reports the state, so
    /// the user sees which one applies instead of a generic failure.
    public var unavailableError: PenBluetoothError? {
        guard !isReady else { return nil }
        return self == .unauthorized ? .permissionDenied : .adapterUnavailable(self)
    }

    /// A short description for an error message.
    public var label: String {
        switch self {
        case .unknown: return "the Bluetooth state is not known yet"
        case .resetting: return "the Bluetooth adapter is resetting"
        case .unsupported: return "this Mac has no Bluetooth LE adapter"
        case .unauthorized: return "Bluetooth access has not been granted"
        case .poweredOff: return "Bluetooth is switched off"
        case .poweredOn: return "Bluetooth is ready"
        }
    }
}

/// One peripheral a scan reports, as the transport sees it.
///
/// The pen advertises a random static address that changes across power cycles,
/// so `id` identifies the peripheral for one connection only. The transport
/// matches on `name` and never stores or displays the address.
public struct PenPeripheral: Hashable, Sendable, Identifiable {
    /// The session-scoped identifier the system assigns to this peripheral.
    public let id: UUID

    /// The advertised local name.
    public let name: String?

    /// Creates a peripheral description.
    public init(id: UUID, name: String?) {
        self.id = id
        self.name = name
    }
}

/// Why Bluetooth discovery, connection, or exchange failed.
///
/// Every case carries a message the app can show, because the shell has no other
/// source for a Bluetooth error description.
public enum PenBluetoothError: Error, Hashable, Sendable {
    /// The user has not granted Bluetooth access.
    case permissionDenied

    /// The adapter is not ready to scan.
    case adapterUnavailable(PenBluetoothState)

    /// A scan ran and no peripheral advertised the pen's name.
    case noMatchingPenFound(advertisedName: String)

    /// Several peripherals advertised the pen's name, so the choice is explicit.
    ///
    /// The candidates carry no address: `PenPeripheral` identifies a peripheral
    /// only for the current scan.
    case multiplePensFound(advertisedName: String, candidates: [PenPeripheral])

    /// The connection attempt failed.
    case connectionFailed(description: String)

    /// A required service or characteristic is absent.
    case missingDataChannel(description: String)

    /// The notify characteristic exists but notifications could not be enabled.
    case notificationEnablementFailed(description: String)

    /// No connection is established.
    case notConnected

    /// A write to the pen failed.
    case writeFailed(description: String)

    /// The user cancelled the attempt.
    case cancelled

    /// The Bluetooth setup phase did not finish before its deadline.
    ///
    /// Scanning is bounded by the selection window, but the connection, the
    /// service discovery, the characteristic discovery, and the notification
    /// subscription all wait on CoreBluetooth callbacks. CoreBluetooth has no
    /// timeout of its own, so a callback that never arrives would leave a read
    /// attempt with no way out but Cancel Read.
    case setupTimedOut(description: String)

    /// A message for the app's error row.
    public var message: String {
        switch self {
        case .permissionDenied:
            return "Bluetooth permission is required. Grant access in System Settings, then try again."
        case .adapterUnavailable(let state):
            return "Bluetooth is unavailable: \(state.label)."
        case .noMatchingPenFound(let advertisedName):
            return "No pen advertising \(advertisedName) was found."
        case .multiplePensFound(let advertisedName, let candidates):
            return "\(candidates.count) pens advertise \(advertisedName). Choose one to read."
        case .connectionFailed(let description):
            return "Could not connect to the pen: \(description)"
        case .missingDataChannel(let description):
            return "The pen does not expose the expected data channel: \(description)"
        case .notificationEnablementFailed(let description):
            return "The pen's notify channel could not be enabled: \(description)"
        case .notConnected:
            return "The pen is not connected."
        case .writeFailed(let description):
            return "Sending to the pen failed: \(description)"
        case .cancelled:
            return "The Bluetooth operation was cancelled."
        case .setupTimedOut(let description):
            return "The pen did not finish connecting: \(description)"
        }
    }
}

/// One connected pen's byte channel.
///
/// The contract matches the portable `PenTransport`: chunks arrive in order, the
/// stream finishes on a clean disconnect, and it throws when the link is
/// interrupted.
public protocol PenBluetoothConnection: Sendable {
    /// The inbound notification chunks, in arrival order.
    func receive() -> AsyncThrowingStream<[UInt8], any Error>

    /// Writes one outbound chunk to the pen's write characteristic.
    func write(_ bytes: [UInt8]) async throws

    /// Drops the connection.
    func close() async
}

/// The CoreBluetooth operations the transport needs.
///
/// Narrowing the surface to these five members is what lets the transport's
/// selection and routing rules run under `swift test` against a fake, because no
/// test needs a radio.
public protocol PenBluetoothCentral: Sendable {
    /// The adapter state at the moment of the call.
    var state: PenBluetoothState { get }

    /// Starts a scan and yields the peripherals it reports.
    ///
    /// The stream finishes when `stopScan()` is called, and throws when the
    /// adapter stops the scan for an error of its own.
    func scan() -> AsyncThrowingStream<PenPeripheral, any Error>

    /// Stops a running scan. Finishing an already-finished scan does nothing.
    func stopScan() async

    /// Connects to one peripheral and prepares its data channel.
    ///
    /// - Throws: `PenBluetoothError` when the connection, the service discovery,
    ///   the characteristic discovery, or the notification setup fails.
    func connect(to peripheral: PenPeripheral) async throws -> any PenBluetoothConnection
}
