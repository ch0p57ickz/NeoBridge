import Foundation
import NeoCore
import Synchronization
import XCTest

@testable import NeoProtocol

/// An ordered log of the events one deleting read produces.
///
/// The barrier and the transport both write into one log, so the interleaving of
/// durable commits and outbound acknowledgements is a single sequence rather than
/// two that a test has to correlate by hand.
final class EventLog: @unchecked Sendable {
    private let store = Mutex<[String]>([])

    /// Every event recorded so far, in order.
    var values: [String] { store.withLock { $0 } }

    /// Records one event.
    func record(_ event: String) {
        store.withLock { $0.append(event) }
    }
}

/// A packet barrier that records each call and can fail or stall one packet.
///
/// The barrier is the session's durable storage, so it is also where a test
/// injects the two failures the acknowledgement bound has to survive: a commit
/// that fails (the packet is never acknowledged) and a commit that takes long
/// enough for the pen to give up.
actor RecordingPacketBarrier: PenDeletingPacketBarrier {
    /// What the barrier does for one packet.
    enum Behavior: Sendable {
        /// Commits normally.
        case commit

        /// Throws before committing anything.
        case fail

        /// Waits for the gate, then commits.
        case wait(Gate)
    }

    private let log: EventLog
    private let behaviors: [Behavior]
    private let failsFinish: Bool
    private var packetCount = 0
    private var strokeCount = 0
    private var recordedPackets: [PenImportPacketProgress] = []
    private var finished: (batchID: UUID, isComplete: Bool)?
    private var failed: UUID?

    init(log: EventLog, behaviors: [Behavior] = [], failsFinish: Bool = false) {
        self.log = log
        self.behaviors = behaviors
        self.failsFinish = failsFinish
    }

    /// The packets the barrier durably committed, in order.
    var packets: [PenImportPacketProgress] { recordedPackets }

    /// How the transfer was finished, or `nil` when it never was.
    var completion: (batchID: UUID, isComplete: Bool)? { finished }

    /// The batch a failure was recorded for, or `nil` when none was.
    var failedBatch: UUID? { failed }

    func beginDeletingRead(notes: [PenDeletingReadNote]) async throws -> UUID {
        log.record("begin")
        packetCount = 0
        strokeCount = 0
        recordedPackets = []
        return UUID()
    }

    func commitDeletingPacket(
        _ packet: PenDeletingPacket
    ) async throws -> PenDeletingPacketCommitResult {
        let index = packetCount
        if behaviors.indices.contains(index) {
            switch behaviors[index] {
            case .commit:
                break
            case .fail:
                log.record("commit-failed(\(packet.packetID))")
                throw InjectedCommitFailure.refused
            case .wait(let gate):
                log.record("commit-waiting(\(packet.packetID))")
                await gate.wait()
            }
        }

        packetCount += 1
        strokeCount += packet.strokes.count
        recordedPackets.append(
            PenImportPacketProgress(
                sectionOwnerID: packet.sectionOwnerID,
                noteID: packet.noteID,
                packetID: packet.packetID,
                strokeCount: packet.strokes.count,
                isEndPacket: packet.isEndPacket
            )
        )
        log.record("commit(\(packet.packetID))")

        return PenDeletingPacketCommitResult(
            committedPacketCount: packetCount,
            committedStrokeCount: strokeCount,
            committedDotCount: packet.strokes.reduce(0) { $0 + $1.points.count },
            addedStrokeCount: packet.strokes.count,
            duplicateStrokeCount: 0,
            isEndPacket: packet.isEndPacket
        )
    }

    func finishDeletingRead(batchID: UUID, isComplete: Bool) async throws {
        // A failure here models storage that accepted every packet but could not
        // write the batch's completion marker.
        if failsFinish {
            log.record("finish-failed")
            throw InjectedCommitFailure.refused
        }
        finished = (batchID, isComplete)
        log.record("finish(complete:\(isComplete))")
    }

    func failDeletingRead(batchID: UUID) async throws {
        failed = batchID
        log.record("fail-batch")
    }
}

/// A commit failure a test injects.
enum InjectedCommitFailure: Error, Hashable {
    case refused
}

/// A gate that holds a caller until a test opens it.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until ``open()``.
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Releases every waiter.
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A transport that yields scripted chunks and can drop the link on a chosen
/// acknowledgement.
///
/// It models a pen that abandons a transfer while the host is still committing
/// the packet it just received: the packet's bytes arrived, the commit ran, and
/// the acknowledgement never reached the pen.
final class AbandoningPenTransport: PenTransport, Sendable {
    private struct State: Sendable {
        var sent: [[UInt8]] = []
        var isClosed = false
    }

    private let inbound: [[UInt8]]
    private let abandonAtAcknowledgement: UInt16?
    private let log: EventLog?
    private let state = Mutex(State())

    /// Creates a transport.
    ///
    /// - Parameters:
    ///   - chunks: Inbound chunks, delivered in order.
    ///   - abandonAtAcknowledgement: The packet identifier whose acknowledgement
    ///     fails, or `nil` to accept every acknowledgement.
    ///   - log: A shared event log the acknowledgements are recorded in.
    init(chunks: [[UInt8]], abandonAtAcknowledgement: UInt16? = nil, log: EventLog? = nil) {
        self.inbound = chunks
        self.abandonAtAcknowledgement = abandonAtAcknowledgement
        self.log = log
    }

    /// Every chunk passed to `send(_:)`, in order.
    var sentChunks: [[UInt8]] { state.withLock { $0.sent } }

    /// Whether `close()` has been called.
    var closed: Bool { state.withLock { $0.isClosed } }

    func receive() -> AsyncThrowingStream<[UInt8], any Error> {
        let chunks = inbound
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        state.withLock { $0.sent.append(bytes) }

        var decoder = PenFrameDecoder()
        guard case .frame(let frame)? = decoder.ingest(bytes).first else { return }

        switch frame.command {
        case .offlineDataRequest1:
            log?.record("request(0x\(String(format: "%02X", frame.payload[0])))")
        case .responseOfflineData:
            let packetID = PenWire.uint16(frame.payload, at: 0)
            let operation = PenTransferAcknowledgement(rawValue: frame.payload[2])
            if let abandonAtAcknowledgement, packetID == abandonAtAcknowledgement {
                // The acknowledgement never left the host: the write failed.
                log?.record("ack-failed(\(packetID))")
                throw InjectedTransportFailure.linkLost
            }
            log?.record("ack(\(packetID),\(operation == .stop ? "stop" : "next"))")
        default:
            break
        }
    }

    func close() async {
        state.withLock { $0.isClosed = true }
    }
}

/// A transport that delivers its first chunks, waits to be released, and then
/// delivers the rest.
///
/// It models a pen that is mid-transfer and still willing to send the next packet,
/// so a test can cancel a read and then prove that the packet the pen went on to
/// offer was never requested or acknowledged.
final class WithholdingPenTransport: PenTransport, Sendable {
    private struct State: Sendable {
        var sent: [[UInt8]] = []
        var isClosed = false
    }

    private let delivered: [[UInt8]]
    private let withheld: [[UInt8]]
    private let state = Mutex(State())
    private let gate = Gate()

    /// Creates a transport.
    ///
    /// - Parameters:
    ///   - delivered: Chunks yielded immediately.
    ///   - withheld: Chunks yielded once ``releaseWithheld()`` is called.
    init(delivered: [[UInt8]], withheld: [[UInt8]]) {
        self.delivered = delivered
        self.withheld = withheld
    }

    /// Every chunk passed to `send(_:)`, in order.
    var sentChunks: [[UInt8]] { state.withLock { $0.sent } }

    /// Whether `close()` has been called.
    var closed: Bool { state.withLock { $0.isClosed } }

    func receive() -> AsyncThrowingStream<[UInt8], any Error> {
        let delivered = self.delivered
        let withheld = self.withheld
        let gate = self.gate
        return AsyncThrowingStream { continuation in
            for chunk in delivered {
                continuation.yield(chunk)
            }
            let producer = Task {
                await gate.wait()
                for chunk in withheld {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Lets the withheld chunks through.
    func releaseWithheld() async {
        await gate.open()
    }

    func send(_ bytes: [UInt8]) async throws {
        state.withLock { $0.sent.append(bytes) }
    }

    func close() async {
        state.withLock { $0.isClosed = true }
    }
}

/// A link failure a test injects.
enum InjectedTransportFailure: Error, Hashable {
    case linkLost
}

/// A test's own failure, thrown so a bounded wait stops the run.
enum TestFailure: Error {
    /// A condition a test was waiting for never held.
    case conditionNeverHeld
}

/// Tests for the deleting `0x23` read: who may request it, what it sends, and the
/// order its durable commits and acknowledgements happen in.
final class DeletingReadSessionTests: XCTestCase {
    private let firstNote = PenOfflineNote(section: 3, owner: 27, note: 700)

    /// The deleting `0x23` frame the 2026-10-21 physical trace recorded.
    private static let tracedDeletingRequest = [
        "C0", "23", "0E", "00", "01", "00", "1B", "00", "00", "03", "BC", "02", "00", "00",
        "00", "00", "00", "00", "C1",
    ].flatMap { UInt8($0, radix: 16).map { [$0] } ?? [] }

    // MARK: - Fixture support

    private func sessionFixture() throws -> ProtocolFixture {
        try FixtureSupport.fixture("a1-offline-session", in: FixtureSupport.all())
    }

    /// The session fixture's chunks, in order.
    private func chunks() throws -> [[UInt8]] {
        try sessionFixture().decodedChunks()
    }

    /// The chunks up to and including the first note's first data packet.
    private func chunksThroughTheFirstPacket() throws -> [[UInt8]] {
        let all = try chunks()
        // The layout is the one `PenSessionTests` asserts: version, note list,
        // page list, info, then the first note's three packets.
        return Array(all.prefix(5))
    }

    private func deletingIntent(
        policy: PenCleanupPolicy = PenCleanupPolicy(),
        requestedExport: Bool = true,
        confirmedForThisSync: Bool = true,
        durablePacketStorageAvailable: Bool = true
    ) -> PenDeletingReadIntent {
        PenDeletingReadIntent(
            policy: policy,
            requestedExport: requestedExport,
            confirmedForThisSync: confirmedForThisSync,
            durablePacketStorageAvailable: durablePacketStorageAvailable
        )
    }

    private func authorization() throws -> PenDeletingReadAuthorization {
        try PenCleanupPolicy()
            .deletingReadAuthorization(
                pen: .physicalA1_2026_10_21,
                requestedExport: true,
                confirmedForThisSync: true,
                durablePacketStorageAvailable: true
            )
            .get()
    }

    // MARK: - The request itself

    func testTheDeletingRequestMatchesTheTracedFraming() throws {
        let frame = try XCTUnwrap(
            PenRequest.offlineData(for: firstNote, deletingRead: try authorization())
        )

        XCTAssertEqual(frame, Self.tracedDeletingRequest)
        XCTAssertEqual(OfflineTransferOption.nextAndDelete.rawValue, 0x01)

        var decoder = PenFrameDecoder()
        let decoded = try XCTUnwrap(decoder.ingest(frame).first)
        guard case .frame(let decodedFrame) = decoded else {
            return XCTFail("the deleting request must be one frame")
        }
        XCTAssertEqual(decodedFrame.command, .offlineDataRequest1)
        XCTAssertEqual(decodedFrame.payload[0], 0x01, "option 0x01 is the deleting transfer")
        XCTAssertEqual(
            decodedFrame.payload[1],
            OfflineCompressionOption.none.rawValue,
            "the traced transfer was uncompressed"
        )
    }

    // MARK: - Who may request it

    func testOrdinaryAndRetentionReadsNeverSendTheDeletingOption() async throws {
        // An ordinary session, and the two non-deleting options the read path can
        // send. None of them may produce option 0x01.
        for option in OfflineReadTransferOption.allCases {
            let transport = FakePenTransport(chunks: try chunks())
            let session = PenSession(transport: transport, transferOption: option)

            _ = try await session.run()

            let options = transport.sentChunks.compactMap { chunk -> UInt8? in
                var decoder = PenFrameDecoder()
                guard case .frame(let frame)? = decoder.ingest(chunk).first,
                    frame.command == .offlineDataRequest1
                else { return nil }
                return frame.payload[0]
            }
            XCTAssertEqual(options.count, 2, "one 0x23 per discovered note")
            XCTAssertFalse(
                options.contains(OfflineTransferOption.nextAndDelete.rawValue),
                "\(option) must not delete during a transfer"
            )
        }
    }

    func testAMissingPreconditionSendsNoDeletingRequestAndNamesIt() async throws {
        // Consent, the export request, and durable storage are each on their own
        // enough to close the route. The read then continues non-destructively, so
        // the blocker is reported rather than the whole read failing.
        let cases: [(PenDeletingReadIntent, PenDeletingReadRefusal)] = [
            (deletingIntent(confirmedForThisSync: false), .notConfirmedForThisSync),
            (deletingIntent(requestedExport: false), .noExportRequested),
            (
                deletingIntent(durablePacketStorageAvailable: false),
                .durableStorageUnavailable(reason: "no writable library is available")
            ),
        ]

        for (intent, refusal) in cases {
            let transport = FakePenTransport(chunks: try chunks())
            let barrier = RecordingPacketBarrier(log: EventLog())
            let session = PenSession(
                transport: transport,
                deletingRead: intent,
                packetBarrier: barrier
            )

            let result = try await session.run()

            XCTAssertEqual(result.deletingReadRefusal, refusal.reason)
            XCTAssertNil(result.deletingTransfer, "no deleting batch may be opened")

            // The read still happened, and no option 0x01 was sent for it.
            XCTAssertEqual(result.notes.count, 2)
            let options = FixtureSupport.outboundOptions(transport.sentChunks)
            XCTAssertEqual(options.count, 2, "one 0x23 per discovered note")
            XCTAssertFalse(
                options.contains(OfflineTransferOption.nextAndDelete.rawValue),
                "a closed deleting route must fall back to the non-destructive option"
            )
            let commits = await barrier.packets
            XCTAssertEqual(commits, [], "a non-destructive read commits no packet")
        }
    }

    func testADeletingReadWithoutAPacketBarrierFallsBackAndNamesIt() async throws {
        let transport = FakePenTransport(chunks: try chunks())
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: nil
        )

        let result = try await session.run()

        XCTAssertEqual(result.deletingReadRefusal, "no durable packet storage is available")
        XCTAssertNil(result.deletingTransfer)
        XCTAssertEqual(result.notes.count, 2, "the read itself must still complete")
        XCTAssertFalse(
            FixtureSupport.outboundOptions(transport.sentChunks)
                .contains(OfflineTransferOption.nextAndDelete.rawValue)
        )
    }

    func testAnUnsupportedPenIdentityClosesTheDeletingRouteAndFallsBack() async throws {
        // The session fixture reports the traced identity, so the route is open for
        // it. The same read with a different reported protocol version must close the
        // deleting route while the read itself continues non-destructively.
        let traced = try chunks()
        var decoder = PenFrameDecoder()
        guard case .frame(let versionFrame)? = decoder.ingest(traced[0]).first else {
            return XCTFail("the fixture's first chunk must be the version response")
        }
        let payload = FixtureSupport.replacing(
            Array("2.23".utf8),
            with: Array("2.18".utf8),
            in: versionFrame.payload
        )
        let rewritten = try XCTUnwrap(
            PenFrameEncoder.encode(
                command: .responseVersionInfo,
                payload: payload,
                errorCode: versionFrame.errorCode ?? 0
            )
        )

        let transport = FakePenTransport(chunks: [rewritten] + traced.dropFirst())
        let barrier = RecordingPacketBarrier(log: EventLog())
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        let result = try await session.run()

        let refusal = try XCTUnwrap(result.deletingReadRefusal)
        XCTAssertTrue(refusal.contains("the deleting-transfer evidence gate is closed"), refusal)
        XCTAssertTrue(refusal.contains("protocol 2.18"), refusal)
        XCTAssertNil(result.deletingTransfer)
        XCTAssertEqual(result.notes.count, 2, "the read itself must still complete")
        XCTAssertFalse(
            FixtureSupport.outboundOptions(transport.sentChunks)
                .contains(OfflineTransferOption.nextAndDelete.rawValue),
            "a mismatched identity must send no deleting option"
        )
        let commits = await barrier.packets
        XCTAssertEqual(commits, [], "a non-destructive read commits no packet")
    }

    // MARK: - Cancellation

    func testCancellingADeletingReadStopsAtTheNextPacketAndReportsTheDurablePrefix() async throws {
        let log = EventLog()
        let barrier = RecordingPacketBarrier(log: log)
        // The pen delivers everything through the first packet and holds the rest
        // back, so the session is waiting for the next packet when the test cancels
        // and the pen still has the rest of the transfer to offer afterwards.
        let all = try chunks()
        let transport = WithholdingPenTransport(
            delivered: Array(all.prefix(5)),
            withheld: Array(all.dropFirst(5))
        )
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        let finished = Mutex(false)
        let attempt = Task { () -> PenSessionResult in
            defer { finished.withLock { $0 = true } }
            return try await session.run()
        }
        try await waitUntil {
            FixtureSupport.outboundAcknowledgements(transport.sentChunks).map(\.packetID) == [1]
        }
        attempt.cancel()
        // Bounded, so a read that ignored the cancellation fails here rather than
        // waiting for a packet the pen is holding back.
        try await waitUntil("the cancelled read did not stop") { finished.withLock { $0 } }

        // The packet whose durable commit had already returned is reported as the
        // prefix, and the read stops there: the pen may already have removed that
        // packet, so this is a partial stop rather than an ordinary cancellation.
        let result = try await attempt.value
        let deleting = try XCTUnwrap(result.deletingTransfer)
        XCTAssertEqual(deleting.committedPacketCount, 1)
        XCTAssertEqual(deleting.committedStrokeCount, 1)
        XCTAssertFalse(deleting.isComplete)
        XCTAssertNotNil(deleting.reason)
        XCTAssertFalse(deleting.acknowledgementUncertain, "packet 1's acknowledgement was sent")

        // The pen goes on to offer the rest of the transfer. None of it is requested
        // or acknowledged, which is the cancellation rule: the read stops at its next
        // inbound wait, and only the packet already in flight may be acknowledged.
        await transport.releaseWithheld()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            FixtureSupport.outboundAcknowledgements(transport.sentChunks).map(\.packetID),
            [1],
            "no acknowledgement follows the cancellation"
        )
        XCTAssertEqual(
            FixtureSupport.outboundOptions(transport.sentChunks).count,
            1,
            "the read requested one note and stopped"
        )
        let commits = await barrier.packets
        XCTAssertEqual(commits.map(\.packetID), [1])
        let completion = await barrier.completion
        XCTAssertEqual(completion?.isComplete, false, "the batch is finished as partial")
    }

    // MARK: - Commit before acknowledgement

    func testEveryDeletingPacketIsCommittedBeforeItsAcknowledgement() async throws {
        let log = EventLog()
        let barrier = RecordingPacketBarrier(log: log)
        let transport = AbandoningPenTransport(chunks: try chunks(), log: log)
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        let result = try await session.run()

        // The interleaving is the deletion bound: the batch opens before the first
        // request, every commit precedes its own acknowledgement, the end packet's
        // commit precedes Stop, and the batch is finished only after the last one.
        XCTAssertEqual(
            log.values,
            [
                "begin",
                "request(0x01)",
                "commit(1)",
                "ack(1,next)",
                "commit(2)",
                "ack(2,next)",
                "commit(3)",
                "ack(3,stop)",
                "request(0x01)",
                "commit(1)",
                "ack(1,stop)",
                "finish(complete:true)",
            ]
        )

        let deleting = try XCTUnwrap(result.deletingTransfer)
        XCTAssertTrue(deleting.isComplete)
        XCTAssertEqual(deleting.committedPacketCount, 4)
        XCTAssertEqual(deleting.committedStrokeCount, 4)
        XCTAssertFalse(deleting.acknowledgementUncertain)
        XCTAssertNil(deleting.reason)
        XCTAssertEqual(deleting.pages.count, 4)

        // The deleting requests are the traced option, and no deletion command was
        // sent at any point.
        let commands = FixtureSupport.outboundCommands(transport.sentChunks)
        XCTAssertEqual(commands.filter { $0 == .offlineDataRequest1 }.count, 2)
        XCTAssertFalse(commands.contains(.deleteOfflineNoteRequest))
        XCTAssertFalse(commands.contains(.deleteOfflinePageRequest))
    }

    func testTheFinalPacketIsCommittedBeforeStop() async throws {
        let log = EventLog()
        let barrier = RecordingPacketBarrier(log: log)
        let transport = AbandoningPenTransport(chunks: try chunks(), log: log)
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        _ = try await session.run()

        let values = log.values
        let stopIndex = try XCTUnwrap(values.firstIndex(of: "ack(3,stop)"))
        let commitIndex = try XCTUnwrap(values.firstIndex(of: "commit(3)"))
        XCTAssertLessThan(commitIndex, stopIndex, "Stop must follow the end packet's commit")
        XCTAssertLessThan(
            try XCTUnwrap(values.firstIndex(of: "ack(3,stop)")),
            try XCTUnwrap(values.firstIndex(of: "finish(complete:true)")),
            "the batch is finished only after Stop was sent"
        )
    }

    // MARK: - Failure

    func testAFailedCommitSendsNoAcknowledgementForThatPacketAndReportsThePrefix() async throws {
        let log = EventLog()
        // The second packet's commit fails, so it must not be acknowledged.
        let barrier = RecordingPacketBarrier(log: log, behaviors: [.commit, .fail])
        let transport = AbandoningPenTransport(chunks: try chunks(), log: log)
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        let result = try await session.run()

        XCTAssertEqual(
            log.values,
            [
                "begin",
                "request(0x01)",
                "commit(1)",
                "ack(1,next)",
                "commit-failed(2)",
                "finish(complete:false)",
            ],
            "a packet whose commit failed is never acknowledged"
        )

        let deleting = try XCTUnwrap(result.deletingTransfer)
        XCTAssertFalse(deleting.isComplete)
        XCTAssertEqual(deleting.committedPacketCount, 1)
        XCTAssertEqual(deleting.committedStrokeCount, 1)
        XCTAssertNotNil(deleting.reason)
        XCTAssertFalse(
            deleting.acknowledgementUncertain,
            "nothing was sent for the failed packet, so its delivery is not uncertain"
        )

        let acknowledgements = FixtureSupport.outboundAcknowledgements(transport.sentChunks)
        XCTAssertEqual(acknowledgements.map(\.packetID), [1])
    }

    func testAFailedFirstCommitThrowsAndFailsTheBatchItOpened() async throws {
        let log = EventLog()
        // The first packet's commit fails, so there is no durable prefix at all.
        let barrier = RecordingPacketBarrier(log: log, behaviors: [.fail])
        let transport = AbandoningPenTransport(chunks: try chunks(), log: log)
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        do {
            _ = try await session.run()
            XCTFail("expected the failed first commit to fail the read")
        } catch let error as PenSessionError {
            guard case .deletingPacketCommitFailed(let reason) = error else {
                return XCTFail("expected a commit failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("refused"), reason)
        }

        // Nothing was acknowledged and no batch was reported: there is no prefix to
        // report, and the failure must surface rather than be forced through one. The
        // batch the read opened is marked failed, because it has nothing in it and the
        // read that opened it has ended.
        XCTAssertEqual(
            log.values,
            ["begin", "request(0x01)", "commit-failed(1)", "fail-batch"],
            "a packet whose commit failed is never acknowledged, and its empty batch is failed"
        )
        let acknowledgements = FixtureSupport.outboundAcknowledgements(transport.sentChunks)
        XCTAssertEqual(acknowledgements, [])
        let commits = await barrier.packets
        XCTAssertEqual(commits, [])
        let completion = await barrier.completion
        XCTAssertNil(completion, "a failed read records no completion")
        let failed = await barrier.failedBatch
        XCTAssertNotNil(failed)
    }

    func testAFailureStartingALaterNoteReportsTheDurablePrefix() async throws {
        let log = EventLog()
        let barrier = RecordingPacketBarrier(log: log)
        let all = try chunks()
        // The first note completes, then the link drops before the second note's
        // page list arrives.
        let transport = AbandoningPenTransport(
            chunks: Array(all.prefix(7)),
            log: log
        )
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        let result = try await session.run()

        // The first note's three packets are durable and the read is partial, not a
        // hard failure: the pen may already have removed that prefix.
        let deleting = try XCTUnwrap(result.deletingTransfer)
        XCTAssertFalse(deleting.isComplete)
        XCTAssertEqual(deleting.committedPacketCount, 3)
        XCTAssertEqual(deleting.committedStrokeCount, 3)
        XCTAssertNotNil(deleting.reason)
        XCTAssertEqual(result.notes.map(\.strokeCount), [3], "only the finished note is reported")
        XCTAssertEqual(
            FixtureSupport.outboundAcknowledgements(transport.sentChunks).map(\.packetID),
            [1, 2, 3]
        )
        XCTAssertEqual(log.values.last, "finish(complete:false)")
    }

    func testAPenThatAbandonsWhileAPacketCommitsLeavesItDurableAndUncertain() async throws {
        let log = EventLog()
        let gate = Gate()
        // The second packet's commit stalls until the test releases it, and the
        // pen has already stopped waiting for that packet's acknowledgement.
        let barrier = RecordingPacketBarrier(log: log, behaviors: [.commit, .wait(gate)])
        let transport = AbandoningPenTransport(
            chunks: try chunks(),
            abandonAtAcknowledgement: 2,
            log: log
        )
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        let attempt = Task { try await session.run() }
        // Wait until the slow commit has started, then release it. Nothing has been
        // acknowledged for packet 2 at that point.
        try await waitUntil { log.values.contains("commit-waiting(2)") }
        XCTAssertFalse(log.values.contains("ack(2,next)"))
        await gate.open()

        let result = try await attempt.value

        let deleting = try XCTUnwrap(result.deletingTransfer)
        XCTAssertEqual(deleting.committedPacketCount, 2, "the stalled packet is durable")
        XCTAssertTrue(deleting.acknowledgementUncertain, "its acknowledgement never arrived")
        XCTAssertFalse(deleting.isComplete, "an abandoned transfer is never complete")
        XCTAssertNotNil(deleting.reason)
        XCTAssertEqual(
            log.values.filter { $0.hasPrefix("ack(") },
            ["ack(1,next)"],
            "the only acknowledgement that left the host is packet 1's"
        )
    }

    // MARK: - A read that ends before its first packet

    /// Asserts that a read which ended before its first durable packet marked the
    /// batch it opened failed, and committed and acknowledged nothing.
    private func assertTheOpenedBatchWasFailed(
        _ barrier: RecordingPacketBarrier,
        log: EventLog,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let failed = await barrier.failedBatch
        XCTAssertNotNil(
            failed,
            "the read must mark the batch it opened failed",
            file: file,
            line: line
        )
        XCTAssertEqual(log.values.first, "begin", file: file, line: line)
        XCTAssertEqual(log.values.last, "fail-batch", file: file, line: line)
        XCTAssertEqual(
            log.values.filter { $0.hasPrefix("commit") },
            [],
            "no packet may be committed on a path that ends before the first one",
            file: file,
            line: line
        )
        let completion = await barrier.completion
        XCTAssertNil(completion, "a failed read records no completion", file: file, line: line)
    }

    func testALinkLossBeforeTheFirstPacketFailsTheBatchItOpened() async throws {
        let log = EventLog()
        let barrier = RecordingPacketBarrier(log: log)
        // The pen answers the page list and then stops sending: the inbound stream
        // ends while the read waits for the data info response.
        let transport = FakePenTransport(chunks: Array(try chunks().prefix(3)))
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        do {
            _ = try await session.run()
            XCTFail("expected a link that ends before the first packet to fail the read")
        } catch let error as PenSessionError {
            XCTAssertEqual(error, .transportEnded(step: .dataInfo))
        }

        // The batch was opened before the 0x23, so it must not be left claiming a
        // transfer that has ended.
        await assertTheOpenedBatchWasFailed(barrier, log: log)
    }

    func testATransportFailureBeforeTheFirstPacketFailsTheBatchItOpened() async throws {
        let log = EventLog()
        let barrier = RecordingPacketBarrier(log: log)
        // The transport reports the connection as interrupted rather than ending it
        // cleanly, which is a different way for the read to stop in the same place.
        let transport = FakePenTransport(
            chunks: Array(try chunks().prefix(3)),
            failure: InjectedTransportFailure.linkLost
        )
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        do {
            _ = try await session.run()
            XCTFail("expected the interrupted connection to fail the read")
        } catch let error as PenSessionError {
            guard case .transportFailure = error else {
                return XCTFail("expected a transport failure, got \(error)")
            }
        }

        await assertTheOpenedBatchWasFailed(barrier, log: log)
    }

    func testARefusedDataInfoFailsTheBatchItOpened() async throws {
        let log = EventLog()
        let barrier = RecordingPacketBarrier(log: log)
        let all = try chunks()
        // The pen refuses the read's request: the 0xA3 carries a nonzero error code,
        // so no packet is ever requested.
        var decoder = PenFrameDecoder()
        guard case .frame(let infoFrame)? = decoder.ingest(all[3]).first else {
            return XCTFail("the fixture's fourth chunk must be the data info response")
        }
        let refused = try XCTUnwrap(
            PenFrameEncoder.encode(
                command: .responseOfflineDataInfo,
                payload: infoFrame.payload,
                errorCode: 1
            )
        )
        let transport = FakePenTransport(chunks: [all[0], all[1], all[2], refused])
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        do {
            _ = try await session.run()
            XCTFail("expected a refused request to fail the read")
        } catch let error as PenSessionError {
            guard case .protocolFailure(.commandFailed(let command, let code)) = error else {
                return XCTFail("expected a refused command, got \(error)")
            }
            XCTAssertEqual(command, .responseOfflineDataInfo)
            XCTAssertEqual(code, 1)
        }

        await assertTheOpenedBatchWasFailed(barrier, log: log)
    }

    func testAMalformedFirstPacketFailsTheBatchItOpened() async throws {
        let log = EventLog()
        let barrier = RecordingPacketBarrier(log: log)
        let all = try chunks()
        // The first data packet is truncated inside its header, so the assembler
        // rejects it before anything is committed for it.
        var decoder = PenFrameDecoder()
        guard case .frame(let packetFrame)? = decoder.ingest(all[4]).first else {
            return XCTFail("the fixture's fifth chunk must be the first data packet")
        }
        let malformed = try XCTUnwrap(
            PenFrameEncoder.encode(
                command: .offlineDataRequest2,
                payload: Array(packetFrame.payload.prefix(4)),
                errorCode: 0
            )
        )
        let transport = FakePenTransport(chunks: [all[0], all[1], all[2], all[3], malformed])
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        do {
            _ = try await session.run()
            XCTFail("expected a malformed first packet to fail the read")
        } catch let error as PenSessionError {
            guard case .protocolFailure(.malformedPayload(let command, _)) = error else {
                return XCTFail("expected a malformed payload, got \(error)")
            }
            XCTAssertEqual(command, .offlineDataRequest2)
        }

        await assertTheOpenedBatchWasFailed(barrier, log: log)
    }

    func testCancellingWhileWaitingForTheFirstPacketFailsTheBatchItOpened() async throws {
        let log = EventLog()
        let barrier = RecordingPacketBarrier(log: log)
        // The pen delivers everything through the data info and holds the first packet
        // back, so the read is waiting for it when the test cancels.
        let all = try chunks()
        let transport = WithholdingPenTransport(
            delivered: Array(all.prefix(4)),
            withheld: Array(all.dropFirst(4))
        )
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        let finished = Mutex(false)
        let attempt = Task { () -> PenSessionResult in
            defer { finished.withLock { $0 = true } }
            return try await session.run()
        }
        try await waitUntil { FixtureSupport.outboundOptions(transport.sentChunks).count == 1 }
        attempt.cancel()
        try await waitUntil("the cancelled read did not stop") { finished.withLock { $0 } }

        do {
            _ = try await attempt.value
            XCTFail("expected a cancellation before the first packet to fail the read")
        } catch let error as PenSessionError {
            XCTAssertEqual(error, .cancelled)
        }

        // Nothing was committed and nothing acknowledged, so there is no prefix to
        // report: the batch is marked failed rather than left in progress.
        XCTAssertEqual(
            FixtureSupport.outboundAcknowledgements(transport.sentChunks),
            [],
            "a cancellation before the first packet acknowledges nothing"
        )
        await assertTheOpenedBatchWasFailed(barrier, log: log)
    }

    // MARK: - Partial reporting

    func testACompletionWriteFailureIsReportedAsNotDurablyComplete() async throws {
        let log = EventLog()
        // Every packet commits, but the completion marker cannot be written, so the
        // batch stays `inProgress`: the report must not claim a completeness its own
        // record does not hold.
        let barrier = RecordingPacketBarrier(log: log, failsFinish: true)
        let transport = AbandoningPenTransport(chunks: try chunks(), log: log)
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        let result = try await session.run()

        let deleting = try XCTUnwrap(result.deletingTransfer)
        XCTAssertEqual(deleting.committedPacketCount, 4, "every packet is durable")
        XCTAssertFalse(deleting.isComplete, "an unrecorded completion is not durable")
        XCTAssertTrue(
            deleting.reachedEndPacket,
            "the transfer itself reached its last packet, which is what the shell reports"
        )
        let reason = try XCTUnwrap(deleting.reason)
        XCTAssertTrue(reason.contains("could not be recorded"), reason)
        XCTAssertEqual(log.values.last, "finish-failed")
    }

    func testAPartialDeletingTransferStillReturnsItsDurablePrefix() async throws {
        let log = EventLog()
        let barrier = RecordingPacketBarrier(log: log)
        // The stream ends after the first packet, which models a pen that closed
        // the link mid-transfer.
        let transport = AbandoningPenTransport(chunks: try chunksThroughTheFirstPacket(), log: log)
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        let result = try await session.run()

        let deleting = try XCTUnwrap(result.deletingTransfer)
        XCTAssertFalse(deleting.isComplete)
        XCTAssertEqual(deleting.committedPacketCount, 1)
        XCTAssertEqual(deleting.committedStrokeCount, 1)
        XCTAssertFalse(deleting.acknowledgementUncertain)
        XCTAssertEqual(result.strokes.count, 1, "the durable prefix is reported as strokes")
        XCTAssertEqual(result.notes.map(\.strokeCount), [1])
        XCTAssertNotNil(log.values.firstIndex(of: "finish(complete:false)"))
    }

    func testADeletingReadWithNothingToReadCommitsNoPacketAndIsComplete() async throws {
        let log = EventLog()
        let barrier = RecordingPacketBarrier(log: log)
        let empty = try FixtureSupport.fixture(
            "a1-offline-note-list-empty",
            in: FixtureSupport.all()
        )
        let chunks = try chunks()
        let emptyNoteList = try empty.decodedChunks()[0]
        let transport = AbandoningPenTransport(chunks: [chunks[0], emptyNoteList], log: log)
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: barrier
        )

        let result = try await session.run()

        // Nothing was discovered, so no batch was opened and no packet was
        // committed: the pen held nothing to remove.
        XCTAssertNil(result.deletingTransfer, "nothing was read, so no batch was reported")
        XCTAssertEqual(log.values, [])
        XCTAssertEqual(FixtureSupport.outboundCommands(transport.sentChunks), [.versionInfo, .offlineNoteListRequest])
    }

    // MARK: - Helpers

    /// Waits until a condition holds, or fails the test and stops it.
    ///
    /// The throw matters for a test that would otherwise wait forever: a bounded
    /// wait that only recorded a failure would leave the next `await` hanging.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ message: String = "the condition never held",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail(message, file: file, line: line)
        throw TestFailure.conditionNeverHeld
    }
}
