import Foundation
import NeoBridgeMacCore
import NeoProtocol
import XCTest

/// Tests for the Bluetooth transport's selection, routing, and signalling rules.
///
/// Every test injects a fake adapter, because no test needs a radio. The fake
/// keeps its scan open until `stopScan()`, which is the contract the transport
/// relies on to collect every match before it decides.
final class CoreBluetoothPenTransportTests: XCTestCase {
    private let penName = CoreBluetoothPenTransport.advertisedName
    private let quickWindow = Duration.milliseconds(20)

    private func peripheral(_ name: String?) -> PenPeripheral {
        PenPeripheral(id: UUID(), name: name)
    }

    // MARK: - Selection

    func testSelectsThePenByAdvertisedNameAndIgnoresOtherDevices() async throws {
        let matching = peripheral(penName)
        let central = FakePenBluetoothCentral(advertisedPeripherals: [
            peripheral("AirPods Pro"),
            peripheral(nil),
            matching,
        ])
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        let selected = try await transport.connect()
        let connected = central.connectedPeripherals

        XCTAssertEqual(selected, matching)
        XCTAssertEqual(connected, [matching])
        XCTAssertTrue(central.didStopScan)
    }

    func testReportsNoMatchingPenWhenNothingAdvertisesTheName() async throws {
        let central = FakePenBluetoothCentral(advertisedPeripherals: [
            peripheral("AirPods Pro")
        ])
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        await assertBluetoothError(.noMatchingPenFound(advertisedName: penName)) {
            try await transport.connect()
        }
        XCTAssertTrue(central.connectedPeripherals.isEmpty)
    }

    func testRequiresAnExplicitChoiceWhenSeveralPensMatch() async throws {
        let first = peripheral(penName)
        let second = peripheral(penName)
        let central = FakePenBluetoothCentral(advertisedPeripherals: [first, second])
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        await assertBluetoothError(
            .multiplePensFound(advertisedName: penName, candidates: [first, second])
        ) {
            try await transport.connect()
        }
        // No pen is picked silently.
        XCTAssertTrue(central.connectedPeripherals.isEmpty)
    }

    func testCountsEachPeripheralOnceEvenWhenTheScanRepeatsIt() async throws {
        let matching = peripheral(penName)
        let central = FakePenBluetoothCentral(advertisedPeripherals: [
            matching,
            matching,
        ])
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        let selected = try await transport.connect()

        XCTAssertEqual(selected, matching)
    }

    func testExplicitSelectionConnectsWithoutScanning() async throws {
        let chosen = peripheral(penName)
        let central = FakePenBluetoothCentral(advertisedPeripherals: [])
        let transport = CoreBluetoothPenTransport(
            central: central,
            selection: .explicit(chosen),
            selectionWindow: quickWindow
        )

        let selected = try await transport.connect()

        XCTAssertEqual(selected, chosen)
        XCTAssertFalse(central.didScan)
        XCTAssertEqual(central.connectedPeripherals, [chosen])
    }

    func testReportsNoMatchingPenWhenTheScanFails() async throws {
        // The pair below is deliberately inconsistent: the scan fails with an
        // adapter error while `state` still reports `.poweredOn`. A real
        // `CoreBluetoothPenCentral` cannot produce it, and this is the point —
        // the test isolates the transport's error-swallowing in
        // `matchesInScanWindow` from its adapter-state check, so the swallow stays
        // covered on its own.
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [],
            scanFailure: .adapterUnavailable(.poweredOff)
        )
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        await assertBluetoothError(.noMatchingPenFound(advertisedName: penName)) {
            try await transport.connect()
        }
    }

    func testAdapterThatGoesAwayMidScanReportsItsStateInsteadOfAMissingPen() async throws {
        // The adapter is ready when the scan starts and is gone by the time the
        // scan window closes, which is what switching Bluetooth off mid-scan
        // looks like. Reporting "no pen was found" would hide the real cause.
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [],
            stateAfterScan: .poweredOff
        )
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        await assertBluetoothError(.adapterUnavailable(.poweredOff)) {
            try await transport.connect()
        }
        XCTAssertTrue(central.connectedPeripherals.isEmpty)
    }

    func testPermissionRevokedMidScanReportsAPermissionError() async throws {
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [],
            stateAfterScan: .unauthorized
        )
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        await assertBluetoothError(.permissionDenied) {
            try await transport.connect()
        }
    }

    func testAPenFoundBeforeTheAdapterGoesAwayStillConnects() async throws {
        // The re-check only applies when the scan found nothing, so a pen
        // reported during the window is still used.
        let matching = peripheral(penName)
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [matching],
            stateAfterScan: .poweredOff
        )
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        let selected = try await transport.connect()

        XCTAssertEqual(selected, matching)
    }

    // MARK: - Scan window

    func testSettlesOnASinglePenWithoutWaitingOutTheWholeWindow() async throws {
        let matching = peripheral(penName)
        let central = FakePenBluetoothCentral(advertisedPeripherals: [matching])
        let transport = CoreBluetoothPenTransport(
            central: central,
            selectionWindow: .seconds(2),
            ambiguityConfirmation: .milliseconds(60)
        )

        let started = ContinuousClock.now
        let selected = try await transport.connect()
        let elapsed = ContinuousClock.now - started

        XCTAssertEqual(selected, matching)
        XCTAssertTrue(central.didStopScan)
        XCTAssertLessThan(
            elapsed,
            .seconds(1),
            "one pen must not wait out the whole window, because the window exists for a second pen"
        )
    }

    func testScanWindowCoversAPenThatHasJustBeenSwitchedOn() throws {
        // The window is sized for the slower of the two observed switch-on cases,
        // not for the awake case: the A1 was once still invisible six seconds after
        // it had been switched on, which is when a read reported "no pen found"
        // with the pen in range, and once advertised about three seconds in.
        XCTAssertGreaterThanOrEqual(
            CoreBluetoothPenTransport.defaultSelectionWindow,
            .seconds(25),
            "the window must cover the delay before a switched-on pen advertises"
        )
        XCTAssertLessThan(
            CoreBluetoothPenTransport.defaultAmbiguityConfirmation,
            CoreBluetoothPenTransport.defaultSelectionWindow,
            "a matched pen must settle the scan well before the maximum"
        )
    }

    func testFindsAPenWhoseFirstAdvertisementArrivesLateInTheWindow() async throws {
        // The physical A1's first advertisement landed up to 2.5 seconds after a
        // scan started, which a short window reports as an absent pen.
        let matching = peripheral(penName)
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [matching],
            advertisementDelay: .milliseconds(150)
        )
        let transport = CoreBluetoothPenTransport(
            central: central,
            selectionWindow: .milliseconds(400),
            ambiguityConfirmation: .milliseconds(60)
        )

        let selected = try await transport.connect()

        XCTAssertEqual(
            selected,
            matching,
            "a silent stretch before the first advertisement is not an absent pen"
        )
    }

    func testReportsNoMatchingPenWhenThePenStaysSilentForTheWholeWindow() async throws {
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [peripheral(penName)],
            advertisementDelay: .seconds(2)
        )
        let transport = CoreBluetoothPenTransport(
            central: central,
            selectionWindow: .milliseconds(250),
            ambiguityConfirmation: .milliseconds(60)
        )

        await assertBluetoothError(.noMatchingPenFound(advertisedName: penName)) {
            try await transport.connect()
        }
    }

    func testCancellingTheScanEndsItAndReportsCancellation() async throws {
        let central = FakePenBluetoothCentral(advertisedPeripherals: [])
        let transport = CoreBluetoothPenTransport(
            central: central,
            selectionWindow: .seconds(5),
            ambiguityConfirmation: .milliseconds(50)
        )

        let attempt = Task { try await transport.connect() }
        try await Task.sleep(for: .milliseconds(150))
        attempt.cancel()

        do {
            _ = try await attempt.value
            XCTFail("expected the cancelled scan to report cancellation")
        } catch {
            XCTAssertEqual(error as? PenBluetoothError, .cancelled)
        }
        XCTAssertTrue(central.didStopScan, "a cancelled scan must not be left running")
    }

    // MARK: - Permission and adapter state

    func testDeniedPermissionReportsAnErrorWithoutScanning() async throws {
        let central = FakePenBluetoothCentral(
            adapterState: .unauthorized,
            advertisedPeripherals: [peripheral(penName)]
        )
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        await assertBluetoothError(.permissionDenied) {
            try await transport.connect()
        }

        // The radio never turns on for a denied request.
        XCTAssertFalse(central.didScan)
    }

    func testAdapterThatIsNotReadyReportsItsState() async throws {
        let central = FakePenBluetoothCentral(
            adapterState: .poweredOff,
            advertisedPeripherals: [peripheral(penName)]
        )
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        await assertBluetoothError(.adapterUnavailable(.poweredOff)) {
            try await transport.connect()
        }
        XCTAssertFalse(central.didScan)
    }

    func testAdapterStateThatIsNotKnownYetIsWaitedForBeforeScanning() async throws {
        // CoreBluetooth reports `.unknown` for a moment after the manager is
        // created, and a read started right after launch lands in that window.
        // Reporting it as unavailable would fail a read the user just asked for.
        let matching = peripheral(penName)
        let central = FakePenBluetoothCentral(
            adapterStateResolvesAfter: .milliseconds(60),
            advertisedPeripherals: [matching]
        )
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        let selected = try await transport.connect()

        XCTAssertEqual(selected, matching)
    }

    func testAdapterStateThatNeverResolvesIsReportedWithoutScanning() async throws {
        let central = FakePenBluetoothCentral(
            adapterState: .unknown,
            advertisedPeripherals: [peripheral(penName)]
        )
        let transport = CoreBluetoothPenTransport(
            central: central,
            selectionWindow: quickWindow,
            adapterStateGrace: .milliseconds(60)
        )

        await assertBluetoothError(.adapterUnavailable(.unknown)) {
            try await transport.connect()
        }
        XCTAssertFalse(central.didScan)
    }

    func testAdapterStatesMapToTheirErrors() throws {
        XCTAssertNil(PenBluetoothState.poweredOn.unavailableError)
        XCTAssertEqual(PenBluetoothState.unauthorized.unavailableError, .permissionDenied)
        XCTAssertEqual(
            PenBluetoothState.poweredOff.unavailableError,
            .adapterUnavailable(.poweredOff)
        )
        XCTAssertEqual(
            PenBluetoothState.unsupported.unavailableError,
            .adapterUnavailable(.unsupported)
        )
        XCTAssertEqual(
            PenBluetoothState.unknown.unavailableError,
            .adapterUnavailable(.unknown)
        )
    }

    // MARK: - Outbound routing

    func testRoutesOutboundBytesToTheWriteChannel() async throws {
        let central = try await connectedCentral()
        let transport = central.transport

        try await transport.send([0x01, 0x02, 0x03])

        XCTAssertEqual(central.central.connection.writes, [[0x01, 0x02, 0x03]])
    }

    func testSlicesAFrameLongerThanTheTransmissionUnit() async throws {
        let central = try await connectedCentral()
        let frame = (0..<45).map { UInt8($0) }

        try await central.transport.send(frame)

        let writes = central.central.connection.writes
        XCTAssertEqual(writes.map(\.count), [20, 20, 5])
        XCTAssertEqual(writes.flatMap { $0 }, frame)
        XCTAssertTrue(
            writes.allSatisfy { $0.count <= PenGATT.maximumTransmissionUnit },
            "every write must fit the transmission unit the SDK documents"
        )
    }

    func testSendingBeforeConnectingReportsNotConnected() async throws {
        let central = FakePenBluetoothCentral()
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        await assertBluetoothError(.notConnected) {
            try await transport.send([0x01])
        }
    }

    // MARK: - Inbound forwarding

    func testEmitsSplitFrameChunksInOrderSoTheDecoderReassemblesOneFrame() async throws {
        let connection = FakePenBluetoothConnection(endsAfterScript: false)
        let central = try await connectedCentral(connection: connection)
        let stream = central.transport.receive()
        let collector = Task { () -> [[UInt8]] in
            var chunks: [[UInt8]] = []
            do {
                for try await chunk in stream {
                    chunks.append(chunk)
                }
            } catch {
                XCTFail("the inbound stream threw: \(error)")
            }
            return chunks
        }

        let frame = FakePenFrames.versionInfo()
        let split = frame.count / 2
        let first = Array(frame[..<split])
        let second = Array(frame[split...])
        connection.emit(first)
        connection.emit(second)
        connection.finishNormally()

        let chunks = await collector.value
        XCTAssertEqual(chunks, [first, second])

        var decoder = PenFrameDecoder()
        let outcomes = chunks.flatMap { decoder.ingest($0) }

        XCTAssertEqual(outcomes.count, 1)
        guard case .frame(let decoded)? = outcomes.first else {
            return XCTFail("expected one decoded frame, got \(outcomes)")
        }
        XCTAssertEqual(decoded.command, .responseVersionInfo)
        XCTAssertEqual(decoded.payload.count, 70)
    }

    func testFinishesTheInboundStreamOnACleanDisconnect() async throws {
        let connection = FakePenBluetoothConnection(endsAfterScript: false)
        let central = try await connectedCentral(connection: connection)
        let stream = central.transport.receive()
        let collector = Task { () -> Bool in
            do {
                for try await _ in stream {}
                return true
            } catch {
                return false
            }
        }

        connection.emit([0x01])
        connection.finishNormally()

        let finishedWithoutError = await collector.value
        XCTAssertTrue(finishedWithoutError)
    }

    func testThrowsWhenTheConnectionIsInterrupted() async throws {
        let connection = FakePenBluetoothConnection(endsAfterScript: false)
        let central = try await connectedCentral(connection: connection)
        let stream = central.transport.receive()
        let collector = Task { () -> (any Error)? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }

        connection.finish(
            throwing: PenBluetoothError.connectionFailed(description: "the link was lost")
        )

        let thrown = await collector.value
        XCTAssertEqual(thrown as? PenBluetoothError, .connectionFailed(description: "the link was lost"))
    }

    func testReceivingWithoutAConnectionReportsNotConnected() async throws {
        let central = FakePenBluetoothCentral()
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)

        let stream = transport.receive()
        let thrown = await Self.firstError(from: stream)

        XCTAssertEqual(thrown as? PenBluetoothError, .notConnected)
    }

    func testCloseDropsTheConnection() async throws {
        let central = try await connectedCentral()

        await central.transport.close()

        XCTAssertTrue(central.central.connection.isClosed)
        XCTAssertFalse(central.transport.isConnected)
    }

    // MARK: - Helpers

    /// A transport already connected to a fake pen.
    private func connectedCentral(
        connection: FakePenBluetoothConnection = FakePenBluetoothConnection()
    ) async throws -> (
        central: FakePenBluetoothCentral, transport: CoreBluetoothPenTransport
    ) {
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [peripheral(penName)],
            connection: connection
        )
        let transport = CoreBluetoothPenTransport(central: central, selectionWindow: quickWindow)
        try await transport.connect()
        return (central, transport)
    }

    /// The first error the stream throws, or `nil` when it finishes.
    private static func firstError(
        from stream: AsyncThrowingStream<[UInt8], any Error>
    ) async -> (any Error)? {
        do {
            for try await _ in stream {}
            return nil
        } catch {
            return error
        }
    }
}

/// Asserts an asynchronous call throws a specific ``PenBluetoothError``.
func assertBluetoothError<T>(
    _ expected: PenBluetoothError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("expected \(expected), but the call succeeded", file: file, line: line)
    } catch let error as PenBluetoothError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), but got \(error)", file: file, line: line)
    }
}
