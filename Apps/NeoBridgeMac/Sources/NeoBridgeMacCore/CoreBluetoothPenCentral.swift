import CoreBluetooth
import Foundation
import Synchronization

/// The CoreBluetooth implementation of ``PenBluetoothCentral``.
///
/// The adapter also implements ``PenBluetoothConnection``, because it carries at
/// most one pen channel at a time: the connected peripheral, its two
/// characteristics, and the notification stream all belong to that single
/// channel. Splitting them into a second object would add indirection without
/// adding isolation.
///
/// Concurrency: every CoreBluetooth call and every delegate callback runs on
/// `queue`, and the mutable state lives behind `Mutex`. A closure handed to
/// `queue` captures only `self` or a sendable value, and it reads the
/// CoreBluetooth objects from the state store inside the queue block, so no
/// `CBPeripheral`, `CBService`, or `CBCharacteristic` value is ever the payload
/// of a sendable closure.
public final class CoreBluetoothPenCentral: NSObject, PenBluetoothCentral, PenBluetoothConnection,
    @unchecked Sendable
{
    /// A waiter that either a delegate callback or a cancellation resumes, never
    /// both.
    private final class DelegateWaiter: @unchecked Sendable {
        private struct Status {
            var continuation: CheckedContinuation<Void, any Error>?
            var isCancelled = false
        }

        private let status = Mutex(Status())

        /// Suspends until the delegate resumes, or until the wait is cancelled.
        ///
        /// - Parameter start: Runs once the continuation is registered, so a
        ///   delegate callback that arrives immediately is never lost.
        func wait(_ start: @escaping @Sendable () -> Void) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    let isAlreadyCancelled = status.withLock { status -> Bool in
                        if status.isCancelled { return true }
                        status.continuation = continuation
                        return false
                    }
                    if isAlreadyCancelled {
                        continuation.resume(throwing: PenBluetoothError.cancelled)
                    } else {
                        start()
                    }
                }
            } onCancel: {
                let pending = status.withLock {
                    status -> CheckedContinuation<Void, any Error>? in
                    status.isCancelled = true
                    defer { status.continuation = nil }
                    return status.continuation
                }
                pending?.resume(throwing: PenBluetoothError.cancelled)
            }
        }

        /// Resumes the waiter from a delegate callback. A second resume does
        /// nothing, so a late callback after cancellation is harmless.
        func resume(_ result: Result<Void, any Error>) {
            let pending = status.withLock {
                status -> CheckedContinuation<Void, any Error>? in
                defer { status.continuation = nil }
                return status.continuation
            }
            pending?.resume(with: result)
        }
    }

    /// The CoreBluetooth objects the adapter currently holds.
    ///
    /// `CBPeripheral`, `CBService`, and `CBCharacteristic` are not `Sendable`.
    /// They live in this one holder, which is reached only through the adapter's
    /// `Mutex`, and every use of them happens on `queue`. That single-queue
    /// discipline is what makes the unchecked conformance sound.
    private final class CoreBluetoothObjects: @unchecked Sendable {
        /// Peripherals the current scan reported, keyed by their session-scoped
        /// identifier. Cleared when a new scan starts, so a connection never
        /// uses a peripheral that is no longer advertising.
        var discovered: [UUID: CBPeripheral] = [:]

        /// The peripheral of the current connection.
        var peripheral: CBPeripheral?

        /// The pen service the current connection discovered.
        var service: CBService?

        /// The characteristic outbound frames are written to.
        var writeCharacteristic: CBCharacteristic?

        /// The characteristic notifications arrive on.
        var notifyCharacteristic: CBCharacteristic?
    }

    private struct State: Sendable {
        /// The CoreBluetooth objects of the current scan and connection.
        let objects = CoreBluetoothObjects()

        /// The last adapter state CoreBluetooth reported, refreshed whenever the
        /// adapter is about to be used. It is cached so a setup step can check
        /// readiness without reading the live manager off `queue`.
        var adapterState: PenBluetoothState = .unknown

        /// The inbound stream of the current connection. A finished stream
        /// cannot be reused, so each connection gets a fresh pair.
        var inbound: AsyncThrowingStream<[UInt8], any Error>?
        var inboundContinuation: InboundContinuation?

        var scanContinuation: AsyncThrowingStream<PenPeripheral, any Error>.Continuation?
        var connectionWaiter: DelegateWaiter?
        var serviceWaiter: DelegateWaiter?
        var characteristicWaiter: DelegateWaiter?
        var notificationWaiter: DelegateWaiter?
        var writeWaiter: DelegateWaiter?

        var isClosed = false
    }

    private typealias InboundContinuation = AsyncThrowingStream<[UInt8], any Error>.Continuation

    private let queue: DispatchQueue
    private let manager: CBCentralManager
    private let store = Mutex(State())

    /// Creates the adapter.
    ///
    /// Creating the central manager is what asks the user for Bluetooth access.
    ///
    /// - Parameter queue: The serial queue for CoreBluetooth callbacks. The
    ///   default is private to this adapter.
    public init(queue: DispatchQueue = DispatchQueue(label: "com.sushidev.neobridge.bluetooth")) {
        self.queue = queue
        // The delegate is attached after `super.init()`, so the manager is
        // created without one: CoreBluetooth accepts a manager whose delegate is
        // set immediately afterwards, and this adapter reads `manager.state` on
        // demand rather than relying on the initial state callback.
        self.manager = CBCentralManager(
            delegate: nil,
            queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        super.init()
        manager.delegate = self
    }

    // MARK: - PenBluetoothCentral

    public var state: PenBluetoothState {
        Self.mapped(manager.state)
    }

    public func scan() -> AsyncThrowingStream<PenPeripheral, any Error> {
        AsyncThrowingStream { continuation in
            store.withLock { $0.scanContinuation = continuation }
            startScan()
        }
    }

    public func stopScan() async {
        let continuation = store.withLock {
            state -> AsyncThrowingStream<PenPeripheral, any Error>.Continuation? in
            defer { state.scanContinuation = nil }
            return state.scanContinuation
        }

        await withCheckedContinuation { done in
            queue.async { [self] in
                manager.stopScan()
                done.resume()
            }
        }
        continuation?.finish()
    }

    public func connect(to peripheral: PenPeripheral) async throws -> any PenBluetoothConnection {
        let isInRange = store.withLock { state -> Bool in
            guard let target = state.objects.discovered[peripheral.id] else { return false }
            state.objects.peripheral = target
            return true
        }
        guard isInRange else {
            throw PenBluetoothError.connectionFailed(
                description: "the pen is no longer in range; scan again"
            )
        }

        // The live manager state is authoritative here, and the cached copy is
        // refreshed so the setup steps below can check it without reading the
        // manager off `queue`.
        store.withLock { $0.adapterState = Self.mapped(manager.state) }

        // Each connection needs its own inbound stream, because a finished
        // stream cannot be reused for a later attempt.
        let (inbound, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
        store.withLock { state in
            state.inbound = inbound
            state.inboundContinuation = continuation
            state.isClosed = false
        }

        do {
            try await connectToDiscoveredPeripheral()
            try await discoverService()
            try await discoverCharacteristics()
            try await enableNotifications()
        } catch {
            // A failed setup must not leave the pen connected, and it must not
            // leave a stream behind that a later attempt could read from.
            await disconnect()
            throw error
        }
        return self
    }

    // MARK: - Connection sequence

    private func connectToDiscoveredPeripheral() async throws {
        try await waitForDelegate(\.connectionWaiter) { [self] in
            queue.async { [self] in
                guard let target = store.withLock({ $0.objects.peripheral }) else { return }
                manager.connect(target, options: nil)
            }
        }
    }

    private func discoverService() async throws {
        try await waitForDelegate(\.serviceWaiter) { [self] in
            queue.async { [self] in
                guard let target = store.withLock({ $0.objects.peripheral }) else { return }
                target.delegate = self
                // Both documented forms are requested, because the SDK declares
                // a 16-bit and a 128-bit identifier for the same service.
                target.discoverServices([
                    CBUUID(string: PenGATT.serviceShortUUID),
                    CBUUID(string: PenGATT.serviceUUID),
                ])
            }
        }
    }

    private func discoverCharacteristics() async throws {
        try await waitForDelegate(\.characteristicWaiter) { [self] in
            queue.async { [self] in
                guard let target = store.withLock({ $0.objects.peripheral }),
                    let service = store.withLock({ $0.objects.service })
                else { return }
                target.discoverCharacteristics(
                    [
                        CBUUID(string: PenGATT.writeCharacteristicShortUUID),
                        CBUUID(string: PenGATT.writeCharacteristicUUID),
                        CBUUID(string: PenGATT.notifyCharacteristicShortUUID),
                        CBUUID(string: PenGATT.notifyCharacteristicUUID),
                    ],
                    for: service
                )
            }
        }
    }

    private func enableNotifications() async throws {
        try await waitForDelegate(\.notificationWaiter) { [self] in
            queue.async { [self] in
                guard let target = store.withLock({ $0.objects.peripheral }),
                    let characteristic = store.withLock({ $0.objects.notifyCharacteristic })
                else { return }
                target.setNotifyValue(true, for: characteristic)
            }
        }
    }

    /// Registers a waiter, starts the CoreBluetooth call, and suspends.
    ///
    /// A step that starts after the adapter went away must fail now rather than
    /// wait for a callback CoreBluetooth will never send, because the state
    /// change has already happened. The cached state closes that order, and
    /// `centralManagerDidUpdateState` closes the other one, where the waiter is
    /// already pending.
    ///
    /// The waits themselves are unbounded: CoreBluetooth has no timeout of its
    /// own, and `BluetoothPenSyncRunner` bounds the whole setup phase.
    private func waitForDelegate(
        _ slot: WritableKeyPath<State, DelegateWaiter?>,
        start: @escaping @Sendable () -> Void
    ) async throws {
        if let error = store.withLock({ $0.adapterState.unavailableError }) {
            throw error
        }

        let waiter = DelegateWaiter()
        store.withLock { $0[keyPath: slot] = waiter }
        try await waiter.wait(start)
    }

    /// Resumes the waiter in a slot, if one is pending.
    private func resumeDelegate(_ slot: WritableKeyPath<State, DelegateWaiter?>) {
        takeWaiter(slot)?.resume(.success(()))
    }

    /// Resumes the waiter in a slot with a failure.
    private func failDelegate(_ slot: WritableKeyPath<State, DelegateWaiter?>, _ error: any Error) {
        takeWaiter(slot)?.resume(.failure(error))
    }

    private func takeWaiter(_ slot: WritableKeyPath<State, DelegateWaiter?>) -> DelegateWaiter? {
        store.withLock { state -> DelegateWaiter? in
            defer { state[keyPath: slot] = nil }
            return state[keyPath: slot]
        }
    }

    // MARK: - PenBluetoothConnection

    public func receive() -> AsyncThrowingStream<[UInt8], any Error> {
        store.withLock { $0.inbound }
            ?? AsyncThrowingStream { $0.finish(throwing: PenBluetoothError.notConnected) }
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard store.withLock({ $0.objects.writeCharacteristic != nil && $0.objects.peripheral != nil }) else {
            throw PenBluetoothError.notConnected
        }

        let waiter = DelegateWaiter()
        store.withLock { $0.writeWaiter = waiter }
        do {
            try await waiter.wait { [self] in
                queue.async { [self] in
                    guard let target = store.withLock({ $0.objects.peripheral }),
                        let characteristic = store.withLock({ $0.objects.writeCharacteristic })
                    else { return }
                    // The SDK writes with response, so every slice is awaited
                    // before the next one is written.
                    target.writeValue(Data(bytes), for: characteristic, type: .withResponse)
                }
            }
        } catch let error as PenBluetoothError {
            // The wait already reports adapter, write, and cancellation failures
            // in the layer's own terms, so they are not re-wrapped.
            throw error
        } catch {
            throw PenBluetoothError.writeFailed(description: String(describing: error))
        }
    }

    public func close() async {
        let shouldClose = store.withLock { state -> Bool in
            defer { state.isClosed = true }
            return !state.isClosed
        }
        guard shouldClose else { return }
        await disconnect()
    }

    // MARK: - Teardown

    /// Drops the pen connection and finishes the inbound stream.
    ///
    /// Finishing an already-finished stream does nothing, so this is safe to
    /// call when a delegate callback has already ended it.
    private func disconnect() async {
        await withCheckedContinuation { done in
            queue.async { [self] in
                if let target = store.withLock({ $0.objects.peripheral }) {
                    if let characteristic = store.withLock({ $0.objects.notifyCharacteristic }) {
                        target.setNotifyValue(false, for: characteristic)
                    }
                    manager.cancelPeripheralConnection(target)
                }
                done.resume()
            }
        }

        let continuation = store.withLock { state -> InboundContinuation? in
            defer {
                state.objects.peripheral = nil
                state.objects.service = nil
                state.objects.writeCharacteristic = nil
                state.objects.notifyCharacteristic = nil
                state.inbound = nil
                state.inboundContinuation = nil
            }
            return state.inboundContinuation
        }
        continuation?.finish()
    }

    // MARK: - Queue helpers

    private func startScan() {
        queue.async { [self] in
            // A previous scan is stopped first, and the discovered set is
            // dropped, so no result survives from an earlier power cycle.
            manager.stopScan()
            store.withLock { $0.objects.discovered.removeAll() }
            manager.scanForPeripherals(
                withServices: [
                    CBUUID(string: PenGATT.serviceShortUUID),
                    CBUUID(string: PenGATT.serviceUUID),
                ],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    // MARK: - Mapping

    private static func mapped(_ state: CBManagerState) -> PenBluetoothState {
        switch state {
        case .unknown: return .unknown
        case .resetting: return .resetting
        case .unsupported: return .unsupported
        case .unauthorized: return .unauthorized
        case .poweredOff: return .poweredOff
        case .poweredOn: return .poweredOn
        @unknown default: return .unknown
        }
    }

    private static func matches(_ uuid: CBUUID, short: String, long: String) -> Bool {
        uuid == CBUUID(string: short) || uuid == CBUUID(string: long)
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothPenCentral: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // While the adapter is ready, its state is read on demand and a change
        // needs no action here. Once it stops being ready, anything already
        // waiting is waiting for a callback that will not come, so the scan and
        // the pending setup waits are failed now. That turns "switched Bluetooth
        // off mid-run" into an adapter error instead of "no pen was found", and
        // spares the user the wait for the setup deadline.
        let adapterState = Self.mapped(central.state)
        store.withLock { $0.adapterState = adapterState }
        // A revoked permission is classified as its own error, so a mid-run
        // revocation reports the same error a setup step checks for.
        guard let error = adapterState.unavailableError else { return }

        let scan = store.withLock {
            store -> AsyncThrowingStream<PenPeripheral, any Error>.Continuation? in
            defer { store.scanContinuation = nil }
            return store.scanContinuation
        }
        scan?.finish(throwing: error)

        failDelegate(\.connectionWaiter, error)
        failDelegate(\.serviceWaiter, error)
        failDelegate(\.characteristicWaiter, error)
        failDelegate(\.notificationWaiter, error)
        failDelegate(\.writeWaiter, error)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let described = PenPeripheral(id: peripheral.identifier, name: peripheral.name)
        let continuation = store.withLock {
            state -> AsyncThrowingStream<PenPeripheral, any Error>.Continuation? in
            state.objects.discovered[peripheral.identifier] = peripheral
            return state.scanContinuation
        }
        continuation?.yield(described)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resumeDelegate(\.connectionWaiter)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        failDelegate(
            \.connectionWaiter,
            PenBluetoothError.connectionFailed(
                description: error.map(String.init(describing:)) ?? "the pen refused the connection"
            )
        )
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        // A disconnect with no error is the normal end of the link, so the
        // inbound stream finishes. An interruption throws, so the session can
        // tell completion from failure.
        let continuation = store.withLock { state -> InboundContinuation? in
            state.objects.peripheral = nil
            return state.inboundContinuation
        }
        if let error {
            continuation?.finish(
                throwing: PenBluetoothError.connectionFailed(description: String(describing: error))
            )
        } else {
            continuation?.finish()
        }

        failDelegate(\.connectionWaiter, PenBluetoothError.notConnected)
        failDelegate(\.serviceWaiter, PenBluetoothError.notConnected)
        failDelegate(\.characteristicWaiter, PenBluetoothError.notConnected)
        failDelegate(\.notificationWaiter, PenBluetoothError.notConnected)
        failDelegate(\.writeWaiter, PenBluetoothError.notConnected)
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothPenCentral: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            failDelegate(
                \.serviceWaiter,
                PenBluetoothError.missingDataChannel(description: String(describing: error))
            )
            return
        }

        let service = peripheral.services?.first { service in
            Self.matches(
                service.uuid,
                short: PenGATT.serviceShortUUID,
                long: PenGATT.serviceUUID
            )
        }
        guard let service else {
            failDelegate(
                \.serviceWaiter,
                PenBluetoothError.missingDataChannel(
                    description: "the pen service \(PenGATT.serviceShortUUID) was not found"
                )
            )
            return
        }

        store.withLock { $0.objects.service = service }
        resumeDelegate(\.serviceWaiter)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        if let error {
            failDelegate(
                \.characteristicWaiter,
                PenBluetoothError.missingDataChannel(description: String(describing: error))
            )
            return
        }

        let characteristics = service.characteristics ?? []
        let write = characteristics.first { characteristic in
            Self.matches(
                characteristic.uuid,
                short: PenGATT.writeCharacteristicShortUUID,
                long: PenGATT.writeCharacteristicUUID
            )
        }
        let notify = characteristics.first { characteristic in
            Self.matches(
                characteristic.uuid,
                short: PenGATT.notifyCharacteristicShortUUID,
                long: PenGATT.notifyCharacteristicUUID
            )
        }

        guard let write, let notify else {
            failDelegate(
                \.characteristicWaiter,
                PenBluetoothError.missingDataChannel(
                    description: "the write or the notify characteristic is absent"
                )
            )
            return
        }

        store.withLock { state in
            state.objects.writeCharacteristic = write
            state.objects.notifyCharacteristic = notify
        }
        resumeDelegate(\.characteristicWaiter)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            failDelegate(
                \.notificationWaiter,
                PenBluetoothError.notificationEnablementFailed(
                    description: String(describing: error)
                )
            )
            return
        }
        guard characteristic.isNotifying else {
            failDelegate(
                \.notificationWaiter,
                PenBluetoothError.notificationEnablementFailed(
                    description: "the pen did not accept the notification subscription"
                )
            )
            return
        }
        resumeDelegate(\.notificationWaiter)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard error == nil, let value = characteristic.value, !value.isEmpty else { return }
        // Chunks are forwarded in arrival order; a frame split across
        // notifications is reassembled by the portable frame decoder.
        store.withLock { $0.inboundContinuation }?.yield([UInt8](value))
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            failDelegate(
                \.writeWaiter,
                PenBluetoothError.writeFailed(description: String(describing: error))
            )
        } else {
            resumeDelegate(\.writeWaiter)
        }
    }
}
