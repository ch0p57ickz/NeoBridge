import Foundation
import NeoBridgeMacCore
import NeoCore
import NeoProtocol
import XCTest

/// Tests for the runner that joins the Bluetooth transport to the portable
/// session, driven by frames the fake pen sends.
final class BluetoothPenSyncRunnerTests: XCTestCase {
    private let penName = CoreBluetoothPenTransport.advertisedName
    private let quickWindow = Duration.milliseconds(20)

    private func pen() -> PenPeripheral {
        PenPeripheral(id: UUID(), name: penName)
    }

    // MARK: - Success

    func testReadsACompleteSessionAndReportsEveryStage() async throws {
        let connection = FakePenBluetoothConnection(inbound: [
            FakePenFrames.versionInfo(),
            FakePenFrames.penState(),
            FakePenFrames.noteList(notes: []),
        ])
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connection: connection
        )
        let runner = BluetoothPenSyncRunner(central: central, selectionWindow: quickWindow)
        let stages = StageRecorder()

        let read = try await runner.run { stages.record($0) }
        let summary = read.summary

        XCTAssertEqual(stages.values, [.scanning, .connecting, .verifying, .syncing])
        XCTAssertTrue(read.transfer.isEmpty, "the read carried no stroke")
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.strokeCount, 0)
        XCTAssertEqual(summary.dotCount, 0)
        XCTAssertEqual(summary.distinctPageCount, 0)
        XCTAssertEqual(read.penState?.batteryLevel, 94)
        XCTAssertEqual(read.penState?.isCharging, false)
        XCTAssertEqual(read.penState?.memoryUsed, 10)
        // A connected pen stops advertising, so a completed read has to release
        // the link or the next read could not find the pen.
        XCTAssertTrue(connection.isClosed, "a completed read leaves the pen disconnected")
    }

    func testNeverSendsADeletionCommand() async throws {
        let connection = FakePenBluetoothConnection(inbound: [
            FakePenFrames.versionInfo(),
            FakePenFrames.penState(),
            FakePenFrames.noteList(notes: []),
        ])
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connection: connection
        )
        let runner = BluetoothPenSyncRunner(central: central, selectionWindow: quickWindow)

        _ = try await runner.run { _ in }

        // Outbound frames are framed, so the command byte is only meaningful once
        // the portable decoder has taken the frame apart.
        var decoder = PenFrameDecoder()
        let commands = decoder.ingest(connection.writtenBytes).compactMap { outcome -> PenCommand? in
            guard case .frame(let frame) = outcome else { return nil }
            return frame.command
        }

        XCTAssertFalse(commands.contains(.deleteOfflineNoteRequest))
        XCTAssertFalse(commands.contains(.deleteOfflinePageRequest))
        XCTAssertTrue(commands.contains(.versionInfo), "the handshake must still be sent")
    }

    func testCarriesAssembledStrokesThroughTheRunner() async throws {
        // The pen discovers the captured note, answers its page list and info
        // request, and sends one packet that completes the transfer.
        let connection = FakePenBluetoothConnection(inbound: [
            FakePenFrames.versionInfo(),
            FakePenFrames.penState(),
            FakePenFrames.noteList(notes: [(FakePenFrames.sectionOwnerId, FakePenFrames.note)]),
            FakePenFrames.pageList(
                sectionOwnerId: FakePenFrames.sectionOwnerId,
                note: FakePenFrames.note,
                pages: [1]
            ),
            FakePenFrames.offlineInfo(strokeCount: 1, uncompressedSize: 0),
            FakePenFrames.offlineStrokePacket(),
        ])
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connection: connection
        )
        let trace = PenTrafficLog()
        let runner = BluetoothPenSyncRunner(
            central: central,
            selectionWindow: quickWindow,
            trace: trace
        )

        let read = try await runner.run { _ in }

        // The counts the shell presents and the strokes the library commits come
        // from the same read, so neither can drift from the other.
        XCTAssertEqual(read.summary.strokeCount, 1)
        XCTAssertEqual(read.summary.dotCount, 1)
        XCTAssertEqual(read.summary.distinctPageCount, 1)
        XCTAssertEqual(read.summary.notes.count, 1)

        XCTAssertEqual(read.transfer.strokeCount, 1)
        XCTAssertEqual(read.transfer.dotCount, 1)
        XCTAssertEqual(read.transfer.noteCount, 1)
        XCTAssertEqual(
            read.transfer.pages,
            [PageIdentity(section: 3, owner: 27, book: 700, page: 1)]
        )
        XCTAssertEqual(read.transfer.strokes.first?.points.count, 1)
        XCTAssertEqual(read.transfer.strokes.first?.source, .offline)

        XCTAssertTrue(
            trace.contents().contains("result strokes=1 dots=1 pages=1 notes=1"),
            "the transcript must still record the counts"
        )
    }

    // MARK: - Transfer option

    /// The frames one complete read of a pen holding a single stroke needs.
    private func oneStrokeRead() -> [[UInt8]] {
        [
            FakePenFrames.versionInfo(),
            FakePenFrames.penState(),
            FakePenFrames.noteList(notes: [(FakePenFrames.sectionOwnerId, FakePenFrames.note)]),
            FakePenFrames.pageList(
                sectionOwnerId: FakePenFrames.sectionOwnerId,
                note: FakePenFrames.note,
                pages: [1]
            ),
            FakePenFrames.offlineInfo(strokeCount: 1, uncompressedSize: 0),
            FakePenFrames.offlineStrokePacket(),
        ]
    }

    /// The payloads of every `0x23` request the connection received.
    private func dataRequestPayloads(
        _ connection: FakePenBluetoothConnection
    ) -> [[UInt8]] {
        var decoder = PenFrameDecoder()
        return decoder.ingest(connection.writtenBytes).compactMap { outcome -> [UInt8]? in
            guard case .frame(let frame) = outcome, frame.command == .offlineDataRequest1 else {
                return nil
            }
            return frame.payload
        }
    }

    /// The runner sends the `0x23` option it was configured with. The acceptance
    /// run varies it while the incremental-transfer experiment runs, and the app's
    /// own default stays the established non-destructive option.
    func testSendsTheTransferOptionItWasConfiguredWith() async throws {
        let cases: [(configured: OfflineReadTransferOption?, byte: UInt8)] = [
            (nil, 0x02),
            (.notNextTransfer, 0x00),
            (.nextAndReserve, 0x02),
        ]

        for (configured, byte) in cases {
            let connection = FakePenBluetoothConnection(inbound: oneStrokeRead())
            let central = FakePenBluetoothCentral(
                advertisedPeripherals: [pen()],
                connection: connection
            )
            let runner = BluetoothPenSyncRunner(
                central: central,
                selectionWindow: quickWindow,
                transferOption: configured ?? .nextAndReserve
            )

            _ = try await runner.run { _ in }

            let payloads = dataRequestPayloads(connection)
            XCTAssertEqual(payloads.count, 1, "one 0x23 for the discovered note")
            XCTAssertEqual(
                payloads.first?.first,
                byte,
                "\(String(describing: configured)) must travel as its own option byte"
            )
        }
    }

    // MARK: - Interrupted transfer

    /// The configured packet drops the link, and the read fails as an interrupted
    /// transfer rather than reporting a result. The experiment needs exactly that:
    /// a read that stops part way with strokes the host never imported.
    func testDropsTheLinkWhenTheConfiguredPacketArrives() async throws {
        let connection = FakePenBluetoothConnection(
            inbound: FakePenFrames.discoveryOnly()
                + [FakePenFrames.offlineStrokePacket(packetID: 1, transferPosition: .start)],
            endsAfterScript: false
        )
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connection: connection
        )
        let trace = PenTrafficLog()
        let runner = BluetoothPenSyncRunner(
            central: central,
            selectionWindow: quickWindow,
            abortAtPacket: 1,
            trace: trace
        )

        await assertSessionError(.incompleteTransfer(assembledPacketCount: 0)) {
            try await runner.run { _ in }
        }

        XCTAssertTrue(connection.isClosed, "the abort has to drop the pen link")
        let contents = trace.contents()
        XCTAssertTrue(
            contents.contains("abort stopped the transfer when 0x24 packet 1 arrived"),
            "the transcript records the abort"
        )
        XCTAssertFalse(contents.contains("result strokes="), "an interrupted transfer is not a result")
    }

    /// The number counts the packets that arrive, so a number the transfer never
    /// reaches leaves the read complete. Without this the experiment could not tell
    /// an aborted transfer from a finished one.
    func testLeavesTheReadCompleteWhenTheConfiguredPacketNeverArrives() async throws {
        let connection = FakePenBluetoothConnection(inbound: oneStrokeRead())
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connection: connection
        )
        let runner = BluetoothPenSyncRunner(
            central: central,
            selectionWindow: quickWindow,
            abortAtPacket: 2
        )

        let read = try await runner.run { _ in }

        XCTAssertEqual(read.summary.strokeCount, 1)
        XCTAssertTrue(connection.isClosed, "a completed read releases the pen")
    }

    /// The transcript carries the stroke identity the experiment compares two runs
    /// and the library by.
    func testRecordsTheStrokeIdentityTheExperimentComparesBy() async throws {
        let connection = FakePenBluetoothConnection(inbound: oneStrokeRead())
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connection: connection
        )
        let trace = PenTrafficLog()
        let runner = BluetoothPenSyncRunner(
            central: central,
            selectionWindow: quickWindow,
            trace: trace
        )

        let read = try await runner.run { _ in }
        let stroke = try XCTUnwrap(read.transfer.strokes.first)
        let fingerprint = StrokeIdentity.fingerprint(of: stroke)

        XCTAssertTrue(
            trace.contents().contains("fp=\(fingerprint.hexDigest.prefix(16))"),
            "a stroke line must carry the identity two runs are compared by"
        )
    }

    // MARK: - Failures

    func testSetupDeadlineOutlastsTheScanWindow() throws {
        // A setup deadline shorter than the scan window would report a setup
        // timeout for a read that was still scanning, which is the same "no pen
        // found" complaint in different words. The default is derived from the
        // window so the two cannot drift apart.
        let window = CoreBluetoothPenTransport.defaultSelectionWindow
        let deadline = BluetoothPenSyncRunner.setupDeadline(for: window)

        XCTAssertGreaterThan(deadline, window)
        XCTAssertGreaterThan(
            deadline,
            BluetoothPenSyncRunner.setupAllowance,
            "the deadline has to cover the connection and discovery steps as well"
        )
    }

    func testRecordsACompletedReadInTheTranscript() async throws {
        let connection = FakePenBluetoothConnection(inbound: [
            FakePenFrames.versionInfo(),
            FakePenFrames.penState(),
            FakePenFrames.noteList(notes: []),
        ])
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connection: connection
        )
        let trace = PenTrafficLog()
        let runner = BluetoothPenSyncRunner(
            central: central,
            selectionWindow: quickWindow,
            trace: trace
        )

        _ = try await runner.run { _ in }

        let contents = trace.contents()
        XCTAssertTrue(contents.contains("state Scanning for a pen"))
        XCTAssertTrue(contents.contains("version text="), "the run record needs the reported version")
        XCTAssertTrue(contents.contains("result strokes=0 dots=0 pages=0 notes=0"))
        XCTAssertTrue(contents.contains("outboundCommands 0x01,0x04,0x21"))
        XCTAssertTrue(contents.contains("state Disconnected"), "the transcript shows the link was released")
        XCTAssertTrue(connection.writtenBytes.isEmpty == false, "the handshake must still be sent")
    }

    func testRecordsASetupFailureInTheTranscript() async throws {
        let central = FakePenBluetoothCentral(
            adapterState: .poweredOff,
            advertisedPeripherals: []
        )
        let trace = PenTrafficLog()
        let runner = BluetoothPenSyncRunner(
            central: central,
            selectionWindow: quickWindow,
            trace: trace
        )

        do {
            _ = try await runner.run { _ in }
            XCTFail("expected the not-ready adapter to fail the attempt")
        } catch {
            XCTAssertEqual(error as? PenBluetoothError, .adapterUnavailable(.poweredOff))
        }

        // A failed attempt records the failure and no result line.
        let contents = trace.contents()
        XCTAssertTrue(contents.contains("failed Bluetooth is unavailable"))
        XCTAssertFalse(contents.contains("result strokes="))
    }

    func testReportsASetupTimeoutWhenTheAdapterNeverAnswers() async throws {
        // CoreBluetooth has no timeout of its own, so a callback that never
        // arrives must be bounded by the runner rather than leave the attempt
        // waiting for Cancel Read.
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connectionStalls: true
        )
        let runner = BluetoothPenSyncRunner(
            central: central,
            selectionWindow: quickWindow,
            setupTimeout: .milliseconds(60)
        )

        do {
            _ = try await runner.run { _ in }
            XCTFail("expected the setup deadline to fire")
        } catch let error as PenBluetoothError {
            guard case .setupTimedOut = error else {
                return XCTFail("expected a setup timeout, got \(error)")
            }
        } catch {
            XCTFail("expected a Bluetooth error, got \(error)")
        }

        // The deadline is a failure, never a completed read: the handshake never
        // began, so no version request reached the pen.
        XCTAssertTrue(central.connection.writes.isEmpty)
    }

    func testStopsBeforeTheHandshakeWhenNotificationSetupFails() async throws {
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connectionFailure: .notificationEnablementFailed(description: "subscription refused")
        )
        let runner = BluetoothPenSyncRunner(central: central, selectionWindow: quickWindow)

        await assertBluetoothError(.notificationEnablementFailed(description: "subscription refused")) {
            try await runner.run { _ in }
        }

        // The handshake never begins, so no version request reaches the pen.
        XCTAssertTrue(central.connection.writes.isEmpty)
    }

    func testReportsATransportEndedFailureWhenTheStreamFinishesDuringTheHandshake() async throws {
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connection: FakePenBluetoothConnection(inbound: [])
        )
        let runner = BluetoothPenSyncRunner(central: central, selectionWindow: quickWindow)

        await assertSessionError(.transportEnded(step: .handshake)) {
            try await runner.run { _ in }
        }
    }

    func testReportsATransportFailureWhenTheConnectionIsInterrupted() async throws {
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connection: FakePenBluetoothConnection(
                inboundFailure: .connectionFailed(description: "the link was lost")
            )
        )
        let runner = BluetoothPenSyncRunner(central: central, selectionWindow: quickWindow)

        do {
            _ = try await runner.run { _ in }
            XCTFail("expected a transport failure")
        } catch let error as PenSessionError {
            guard case .transportFailure(let description) = error else {
                return XCTFail("expected a transport failure, got \(error)")
            }
            XCTAssertTrue(description.contains("the link was lost"))
        } catch {
            XCTFail("expected a session error, got \(error)")
        }
    }

    func testReportsAnIncompleteTransferWhenTheStreamFinishesBeforeTheEndPacket() async throws {
        // The pen discovers a note, answers the page list and the info request,
        // and then the link goes quiet without an end-position packet.
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connection: FakePenBluetoothConnection(inbound: FakePenFrames.discoveryOnly())
        )
        let runner = BluetoothPenSyncRunner(central: central, selectionWindow: quickWindow)

        await assertSessionError(.incompleteTransfer(assembledPacketCount: 0)) {
            try await runner.run { _ in }
        }
    }

    // MARK: - Discovery gating

    func testFailsBeforeDiscoveryWhenThePenReportsAnUnvalidatedVersion() async throws {
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen()],
            connection: FakePenBluetoothConnection(inbound: [FakePenFrames.versionInfo(protocolVersion: "2.5")])
        )
        let runner = BluetoothPenSyncRunner(central: central, selectionWindow: quickWindow)

        await assertSessionError(.unsupportedVersion(ProtocolVersion(major: 2, minor: 5))) {
            try await runner.run { _ in }
        }

        var decoder = PenFrameDecoder()
        let commands = decoder.ingest(central.connection.writtenBytes).compactMap {
            outcome -> PenCommand? in
            guard case .frame(let frame) = outcome else { return nil }
            return frame.command
        }
        XCTAssertEqual(commands, [.versionInfo], "an unsupported version must not lead to a list request")
    }
}

/// Asserts an asynchronous call throws a specific ``PenSessionError``.
func assertSessionError<T>(
    _ expected: PenSessionError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("expected \(expected), but the call succeeded", file: file, line: line)
    } catch let error as PenSessionError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), but got \(error)", file: file, line: line)
    }
}
