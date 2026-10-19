import Foundation
import NeoCore
import Synchronization
import XCTest

@testable import NeoProtocol

final class PenSessionTests: XCTestCase {
    // The note the physical A1 capture read, plus a second note the pen lists.
    private let firstNote = PenOfflineNote(section: 3, owner: 27, note: 700)
    private let secondNote = PenOfflineNote(section: 3, owner: 27, note: 701)

    private let patientTimeouts = PenSessionTimeouts(
        handshake: .seconds(30),
        noteList: .seconds(30),
        pageList: .seconds(30),
        dataInfo: .seconds(30),
        dataPacket: .seconds(30)
    )

    // MARK: - Fixture support

    /// A session over the fixture that holds the whole read path.
    private func sessionFixture() throws -> ProtocolFixture {
        try FixtureSupport.fixture("a1-offline-session", in: FixtureSupport.all())
    }

    /// The fixture's chunks, split so the frames are easy to name.
    private struct SessionChunks {
        let version: [UInt8]
        let noteList: [UInt8]
        let firstPageList: [UInt8]
        let firstInfo: [UInt8]
        let firstPackets: [[UInt8]]
        let secondPageList: [UInt8]
        let secondInfo: [UInt8]
        let secondPackets: [[UInt8]]

        /// Every chunk, in the order the fixture lists them.
        var all: [[UInt8]] {
            [version, noteList, firstPageList, firstInfo]
                + firstPackets
                + [secondPageList, secondInfo]
                + secondPackets
        }

        /// Every chunk after the handshake.
        var afterHandshake: [[UInt8]] {
            Array(all.dropFirst())
        }
    }

    private func sessionChunks() throws -> SessionChunks {
        let chunks = try sessionFixture().decodedChunks()
        // The layout is asserted so a fixture change fails here rather than
        // silently reinterpreting an index.
        let commands: [PenCommand?] = chunks.map { chunk in
            var decoder = PenFrameDecoder()
            guard case .frame(let frame)? = decoder.ingest(chunk).first else { return nil }
            return frame.command
        }
        let expected: [PenCommand?] = [
            .responseVersionInfo,
            .responseOfflineNoteList,
            .responseOfflinePageList,
            .responseOfflineDataInfo,
            .offlineDataRequest2,
            .offlineDataRequest2,
            .offlineDataRequest2,
            .responseOfflinePageList,
            .responseOfflineDataInfo,
            .offlineDataRequest2
        ]
        XCTAssertEqual(commands, expected, "the session fixture's chunk order changed")

        return SessionChunks(
            version: chunks[0],
            noteList: chunks[1],
            firstPageList: chunks[2],
            firstInfo: chunks[3],
            firstPackets: [chunks[4], chunks[5], chunks[6]],
            secondPageList: chunks[7],
            secondInfo: chunks[8],
            secondPackets: [chunks[9]]
        )
    }

    private func makeSession(
        transport: PenTransport,
        bootstrap: PenOfflineDiscoveryBootstrap = .neoSDK3,
        timeouts: PenSessionTimeouts = .default,
        versionPolicy: ProtocolVersionPolicy = .neoSDK3,
        recorder: StateRecorder? = nil
    ) -> PenSession {
        var onStateChange: (@Sendable (PenSessionState) -> Void)?
        if let recorder {
            onStateChange = { state in recorder.record(state) }
        }
        return PenSession(
            transport: transport,
            versionPolicy: versionPolicy,
            timeouts: timeouts,
            bootstrap: bootstrap,
            onStateChange: onStateChange
        )
    }

    // MARK: - Lifecycle

    func testSessionReportsEveryLifecycleStateInOrder() async throws {
        let fixture = try sessionFixture()
        let transport = FakePenTransport(chunks: try fixture.decodedChunks())
        let recorder = StateRecorder()
        let session = makeSession(transport: transport, recorder: recorder)

        XCTAssertEqual(session.state, .idle)

        let result = try await session.run()

        XCTAssertEqual(recorder.all, [.connecting, .verifying, .syncing, .complete])
        XCTAssertEqual(session.state, .complete)

        XCTAssertEqual(result.version, ProtocolVersion(major: 2, minor: 23))
        XCTAssertEqual(result.strokeCount, 4)
        XCTAssertEqual(result.dotCount, 9)
        XCTAssertEqual(result.distinctPageCount, 4, "the transfers span pages 1, 16, 17, and 2")
        XCTAssertEqual(result.notes.map(\.note), [firstNote, secondNote])
        XCTAssertEqual(result.notes.map(\.strokeCount), [3, 1])
        XCTAssertEqual(result.notes.map(\.packetCount), [3, 1])
        XCTAssertEqual(result.notes[0].listedPages, [1, 16, 17])
        XCTAssertEqual(result.notes[1].listedPages, [2])
        XCTAssertEqual(result.notes[0].pageIdentities.map(\.page), [1, 16, 17])
        XCTAssertFalse(result.isEmpty)
    }

    func testCountsComeFromThePacketsNotTheLaggingSummary() async throws {
        let fixture = try sessionFixture()
        let session = makeSession(transport: FakePenTransport(chunks: try fixture.decodedChunks()))

        let result = try await session.run()

        // The fixture's two 0xA3 responses report one stroke each while the
        // packet stream carries three and one, which is the lagging index the
        // physical A1 showed.
        XCTAssertEqual(result.notes.map(\.info.strokeCount), [1, 1])
        XCTAssertEqual(result.notes.map(\.strokeCount), [3, 1])
        XCTAssertEqual(result.strokeCount, 4)
    }

    func testSessionSendsTheDocumentedRequestSequence() async throws {
        let chunks = try sessionChunks()
        let transport = FakePenTransport(chunks: chunks.all)
        let session = makeSession(transport: transport)

        _ = try await session.run()

        let expected: [[UInt8]] = [
            try XCTUnwrap(PenRequest.versionInfo()),
            try XCTUnwrap(PenRequest.noteList()),
            try XCTUnwrap(PenRequest.pageList(for: firstNote)),
            try XCTUnwrap(PenRequest.offlineData(for: firstNote)),
            try XCTUnwrap(PenRequest.acknowledgement(packetID: 1, operation: .next)),
            try XCTUnwrap(PenRequest.acknowledgement(packetID: 2, operation: .next)),
            try XCTUnwrap(PenRequest.acknowledgement(packetID: 3, operation: .stop)),
            try XCTUnwrap(PenRequest.pageList(for: secondNote)),
            try XCTUnwrap(PenRequest.offlineData(for: secondNote)),
            try XCTUnwrap(PenRequest.acknowledgement(packetID: 1, operation: .stop))
        ]
        XCTAssertEqual(transport.sentChunks, expected)
    }

    func testSessionHandshakeMatchesTheCapturedExchange() async throws {
        let chunks = try sessionChunks()
        let transport = FakePenTransport(chunks: chunks.all)
        let session = makeSession(transport: transport)

        _ = try await session.run()

        // The 0x01 request the session builds must be the bytes the physical A1
        // accepted, so the layout is anchored to the capture rather than to a
        // separate reading of the SDK.
        let capture = try FixtureSupport.fixture("a1-handshake-version-2.23", in: FixtureSupport.all())
        let capturedRequest = try XCTUnwrap(capture.decodedChunks().first)
        XCTAssertEqual(transport.sentChunks.first, capturedRequest)

        // The session fixture opens with the capture's own version response, so
        // both fixtures report the same device facts.
        let capturedResponse = try XCTUnwrap(capture.decodedChunks().last)
        XCTAssertEqual(chunks.version, capturedResponse)
    }

    func testDeletionCommandsStayBlockedAndUnencodable() throws {
        // The keep-on-pen guarantee asserted at the evidence layer: neither
        // deletion command may be sent, and neither has a recorded framing, so
        // neither can even be encoded.
        for command in [PenCommand.deleteOfflineNoteRequest, .deleteOfflinePageRequest] {
            XCTAssertFalse(
                CommandEvidenceRegistry.neoSDK3.maySendProductionRequest(command),
                "\(command) must not be sendable while cleanup stays on the pen"
            )
            XCTAssertFalse(
                CommandEvidenceRegistry.neoSDK3.authorization(for: command).allowsCompletedStroke
            )
            XCTAssertNil(command.frameKind, "\(command) has no recorded framing")
            XCTAssertNil(PenFrameEncoder.encode(command: command, payload: [0, 0, 0, 0]))
        }
    }

    func testCompletedSyncSendsNoDeletionCommand() async throws {
        let fixture = try sessionFixture()
        let transport = FakePenTransport(chunks: try fixture.decodedChunks())
        let session = makeSession(transport: transport)

        _ = try await session.run()

        let commands = FixtureSupport.outboundCommands(transport.sentChunks)
        XCTAssertEqual(commands.count, transport.sentChunks.count)
        XCTAssertFalse(commands.isEmpty)
        XCTAssertFalse(commands.contains(.deleteOfflineNoteRequest))
        XCTAssertFalse(commands.contains(.deleteOfflinePageRequest))
    }

    // MARK: - Version gate

    func testRejectedConnectionCodeFailsWithoutTryingAnotherCode() async throws {
        // A version response carrying a non-zero error code means the pen refused
        // the SDK's default connection code.
        let rejection = try XCTUnwrap(
            PenFrameEncoder.encode(command: .responseVersionInfo, payload: [], errorCode: 0x02)
        )
        let transport = FakePenTransport(chunks: [rejection])
        let session = makeSession(transport: transport)

        do {
            _ = try await session.run()
            XCTFail("expected the handshake to fail")
        } catch let error as PenSessionError {
            XCTAssertEqual(error, .penRejectedHandshake(code: 0x02))
            XCTAssertEqual(session.state, .failed(error))
        }

        // Exactly one frame went out: the session did not guess another code.
        XCTAssertEqual(transport.sentChunks.count, 1)
        XCTAssertEqual(FixtureSupport.outboundCommands(transport.sentChunks), [.versionInfo])
        XCTAssertTrue(transport.closed, "a failed session must close its transport")
    }

    func testUnvalidatedMinorReportsUnsupportedAndSendsNoOfflineRequest() async throws {
        let fixture = try FixtureSupport.fixture("a1-version-info-2.18", in: FixtureSupport.all())
        let transport = FakePenTransport(chunks: try fixture.decodedChunks())
        // 2.18 is validated by default; this policy validates no minor, which is
        // the shape a pen outside the validated set takes.
        let session = makeSession(
            transport: transport,
            versionPolicy: ProtocolVersionPolicy(validatedMinors: [])
        )

        do {
            _ = try await session.run()
            XCTFail("expected the version gate to refuse the pen")
        } catch let error as PenSessionError {
            XCTAssertEqual(error, .unsupportedVersion(ProtocolVersion(major: 2, minor: 18)))
        }

        XCTAssertEqual(
            FixtureSupport.outboundCommands(transport.sentChunks),
            [.versionInfo],
            "an unvalidated version must not trigger an offline request"
        )
    }

    func testValidatedMinorProceedsToDiscovery() async throws {
        let fixture = try FixtureSupport.fixture("a1-version-info-2.18", in: FixtureSupport.all())
        let transport = FakePenTransport(chunks: try fixture.decodedChunks())
        let session = makeSession(transport: transport)

        // The stream holds no note list, so the session stops there; what matters
        // is that it asked.
        _ = try? await session.run()

        XCTAssertEqual(
            FixtureSupport.outboundCommands(transport.sentChunks),
            [.versionInfo, .offlineNoteListRequest]
        )
    }

    func testDiscoveryWithoutEvidenceSendsNoListRequest() async throws {
        let fixture = try sessionFixture()
        let transport = FakePenTransport(chunks: try fixture.decodedChunks())
        let session = makeSession(
            transport: transport,
            bootstrap: .unavailable(reason: "no recorded initial section-owner value")
        )

        do {
            _ = try await session.run()
            XCTFail("expected discovery to be refused")
        } catch let error as PenSessionError {
            XCTAssertEqual(
                error,
                .discoveryUnsupported(reason: "no recorded initial section-owner value")
            )
        }

        XCTAssertEqual(
            FixtureSupport.outboundCommands(transport.sentChunks),
            [.versionInfo],
            "an unestablished section and owner must not produce a list request"
        )
    }

    // MARK: - Discovery

    func testEmptyNoteListCompletesWithZeroCountsAndNoDataRequest() async throws {
        let chunks = try sessionChunks()
        let empty = try FixtureSupport.fixture(
            "a1-offline-note-list-empty",
            in: FixtureSupport.all()
        ).decodedChunks()
        let transport = FakePenTransport(chunks: [chunks.version] + empty)
        let session = makeSession(transport: transport)

        let result = try await session.run()

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.strokeCount, 0)
        XCTAssertEqual(result.dotCount, 0)
        XCTAssertEqual(result.distinctPageCount, 0)
        XCTAssertEqual(
            FixtureSupport.outboundCommands(transport.sentChunks),
            [.versionInfo, .offlineNoteListRequest]
        )
    }

    func testMalformedNoteListFailsBeforeRequestingAnyNoteData() async throws {
        let chunks = try sessionChunks()
        let malformed = try FixtureSupport.fixture(
            "a1-offline-note-list-malformed",
            in: FixtureSupport.all()
        ).decodedChunks()
        let transport = FakePenTransport(chunks: [chunks.version] + malformed)
        let session = makeSession(transport: transport)

        do {
            _ = try await session.run()
            XCTFail("expected the malformed list to stop retrieval")
        } catch let error as PenSessionError {
            guard case .protocolFailure(.malformedPayload(let command, let reason)) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(command, .responseOfflineNoteList)
            XCTAssertTrue(reason.contains("declares 2 notes"), reason)
        }

        XCTAssertEqual(
            FixtureSupport.outboundCommands(transport.sentChunks),
            [.versionInfo, .offlineNoteListRequest],
            "no 0x22 or 0x23 may follow a list that cannot be decoded"
        )
    }

    func testNonZeroResponseErrorFailsWithoutTreatingThePayloadAsData() async throws {
        let chunks = try sessionChunks()
        // The page list answers with an error, so its payload is not data.
        let failingPageList = try XCTUnwrap(
            PenFrameEncoder.encode(command: .responseOfflinePageList, payload: [], errorCode: 0x05)
        )
        let transport = FakePenTransport(chunks: [chunks.version, chunks.noteList, failingPageList])
        let session = makeSession(transport: transport)

        do {
            _ = try await session.run()
            XCTFail("expected the failed response to stop retrieval")
        } catch let error as PenSessionError {
            XCTAssertEqual(
                error,
                .protocolFailure(.commandFailed(command: .responseOfflinePageList, code: 0x05))
            )
        }

        XCTAssertFalse(
            FixtureSupport.outboundCommands(transport.sentChunks).contains(.offlineDataRequest1),
            "a failed response must not be followed by a data request"
        )
    }

    func testALaterNoteFailureIsReportedWithoutCompletingTheSync() async throws {
        let chunks = try sessionChunks()
        let transport = ConversationPenTransport(exchanges: [
            .init(expects: try XCTUnwrap(PenRequest.versionInfo()), emits: [chunks.version]),
            .init(expects: try XCTUnwrap(PenRequest.noteList()), emits: [chunks.noteList]),
            .init(
                expects: try XCTUnwrap(PenRequest.pageList(for: firstNote)),
                emits: [chunks.firstPageList]
            ),
            .init(
                expects: try XCTUnwrap(PenRequest.offlineData(for: firstNote)),
                emits: [chunks.firstInfo, chunks.firstPackets[0]]
            ),
            .init(
                expects: try XCTUnwrap(PenRequest.acknowledgement(packetID: 1, operation: .next)),
                emits: [chunks.firstPackets[1]]
            ),
            .init(
                expects: try XCTUnwrap(PenRequest.acknowledgement(packetID: 2, operation: .next)),
                emits: [chunks.firstPackets[2]]
            ),
            .init(
                expects: try XCTUnwrap(PenRequest.acknowledgement(packetID: 3, operation: .stop)),
                emits: []
            ),
            // The second note's page list answers with an error.
            .init(
                expects: try XCTUnwrap(PenRequest.pageList(for: secondNote)),
                emits: [
                    try XCTUnwrap(
                        PenFrameEncoder.encode(
                            command: .responseOfflinePageList,
                            payload: [],
                            errorCode: 0x05
                        )
                    )
                ]
            )
        ])
        let session = makeSession(transport: transport)

        do {
            let result = try await session.run()
            XCTFail("expected the second note to fail the sync, got \(result.strokeCount) strokes")
        } catch let error as PenSessionError {
            XCTAssertEqual(
                error,
                .protocolFailure(.commandFailed(command: .responseOfflinePageList, code: 0x05))
            )
            XCTAssertEqual(session.state, .failed(error))
        }

        XCTAssertTrue(transport.closed)
    }

    // MARK: - Transfer pacing and acknowledgements

    func testAcknowledgementControlsThePacketStream() async throws {
        let chunks = try sessionChunks()
        let transport = ConversationPenTransport(exchanges: [
            .init(expects: try XCTUnwrap(PenRequest.versionInfo()), emits: [chunks.version]),
            .init(expects: try XCTUnwrap(PenRequest.noteList()), emits: [chunks.noteList]),
            .init(
                expects: try XCTUnwrap(PenRequest.pageList(for: firstNote)),
                emits: [chunks.firstPageList]
            ),
            // One packet rides with the info response, and each later packet is
            // released only by the acknowledgement before it.
            .init(
                expects: try XCTUnwrap(PenRequest.offlineData(for: firstNote)),
                emits: [chunks.firstInfo, chunks.firstPackets[0]]
            ),
            .init(
                expects: try XCTUnwrap(PenRequest.acknowledgement(packetID: 1, operation: .next)),
                emits: [chunks.firstPackets[1]]
            ),
            .init(
                expects: try XCTUnwrap(PenRequest.acknowledgement(packetID: 2, operation: .next)),
                emits: [chunks.firstPackets[2]]
            ),
            .init(
                expects: try XCTUnwrap(PenRequest.acknowledgement(packetID: 3, operation: .stop)),
                emits: []
            ),
            .init(
                expects: try XCTUnwrap(PenRequest.pageList(for: secondNote)),
                emits: [chunks.secondPageList]
            ),
            .init(
                expects: try XCTUnwrap(PenRequest.offlineData(for: secondNote)),
                emits: [chunks.secondInfo] + chunks.secondPackets
            ),
            .init(
                expects: try XCTUnwrap(PenRequest.acknowledgement(packetID: 1, operation: .stop)),
                emits: []
            )
        ])
        let session = makeSession(transport: transport)

        let result = try await session.run()

        XCTAssertNil(transport.failure)
        XCTAssertEqual(transport.remainingExchangeCount, 0, "the whole scripted conversation ran")
        XCTAssertEqual(result.strokeCount, 4)
        XCTAssertEqual(result.notes.map(\.packetCount), [3, 1])

        // One acknowledgement per packet: Continue for every packet that is not
        // the end of its transfer, Stop for the one that is.
        XCTAssertEqual(
            FixtureSupport.outboundAcknowledgements(transport.sentChunks),
            [
                SentAcknowledgement(packetID: 1, operation: .next),
                SentAcknowledgement(packetID: 2, operation: .next),
                SentAcknowledgement(packetID: 3, operation: .stop),
                SentAcknowledgement(packetID: 1, operation: .stop)
            ]
        )
    }

    func testPacketGapFailsTheTransfer() async throws {
        let chunks = try sessionChunks()
        let transport = ConversationPenTransport(exchanges: [
            .init(expects: try XCTUnwrap(PenRequest.versionInfo()), emits: [chunks.version]),
            .init(expects: try XCTUnwrap(PenRequest.noteList()), emits: [chunks.noteList]),
            .init(
                expects: try XCTUnwrap(PenRequest.pageList(for: firstNote)),
                emits: [chunks.firstPageList]
            ),
            .init(
                expects: try XCTUnwrap(PenRequest.offlineData(for: firstNote)),
                emits: [chunks.firstInfo, chunks.firstPackets[0]]
            ),
            // Skip the second packet, as a lost acknowledgement would.
            .init(
                expects: try XCTUnwrap(PenRequest.acknowledgement(packetID: 1, operation: .next)),
                emits: [chunks.firstPackets[2]]
            )
        ])
        let session = makeSession(transport: transport)

        do {
            _ = try await session.run()
            XCTFail("expected the packet gap to fail the transfer")
        } catch let error as PenSessionError {
            guard case .protocolFailure(.malformedPayload(_, let reason)) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(reason.contains("does not follow"), reason)
        }
    }

    func testStreamEndingBeforeTheEndPacketIsIncomplete() async throws {
        let chunks = try sessionChunks()
        // The stream finishes normally after one start packet and no end packet.
        let transport = FakePenTransport(
            chunks: [
                chunks.version,
                chunks.noteList,
                chunks.firstPageList,
                chunks.firstInfo,
                chunks.firstPackets[0]
            ]
        )
        let session = makeSession(transport: transport)

        do {
            _ = try await session.run()
            XCTFail("expected an incomplete transfer")
        } catch let error as PenSessionError {
            XCTAssertEqual(error, .incompleteTransfer(assembledPacketCount: 1))
            guard case .failed = session.state else {
                return XCTFail("a partial transfer must not appear complete")
            }
        }
    }

    func testUnsupportedCompressedTransferFailsTheSession() async throws {
        let chunks = try sessionChunks()
        // Flip the compression flag of the first data packet.
        var payload = try XCTUnwrap(
            FixtureSupport.offlineDataFrames(try sessionFixture()).first?.payload
        )
        payload[2] = 1
        let compressed = try XCTUnwrap(
            PenFrameEncoder.encode(command: .offlineDataRequest2, payload: payload)
        )
        let transport = FakePenTransport(
            chunks: [
                chunks.version,
                chunks.noteList,
                chunks.firstPageList,
                chunks.firstInfo,
                compressed
            ]
        )
        let session = makeSession(transport: transport)

        do {
            _ = try await session.run()
            XCTFail("expected the compressed transfer to be refused")
        } catch let error as PenSessionError {
            guard case .unsupportedTransfer(let reason) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(reason.contains("compressed"), reason)
        }
    }

    func testFrameSplitAcrossChunksReassemblesAndDecodes() async throws {
        let chunks = try sessionChunks()
        // Deliver the whole version frame as two chunks, the way a large frame
        // arrives across two BLE notifications.
        let split = chunks.version.count / 2
        let transport = FakePenTransport(
            chunks: [
                Array(chunks.version[..<split]),
                Array(chunks.version[split...])
            ] + chunks.afterHandshake
        )
        let session = makeSession(transport: transport)

        let result = try await session.run()

        XCTAssertEqual(result.version, ProtocolVersion(major: 2, minor: 23))
        XCTAssertEqual(result.strokeCount, 4)
    }

    // MARK: - Bounded waits, cancellation, and retry

    func testSilentPenTimesOutOnTheNoteListAndClosesTheTransport() async throws {
        let chunks = try sessionChunks()
        let transport = StalledPenTransport(chunks: [chunks.version])
        let session = makeSession(
            transport: transport,
            timeouts: PenSessionTimeouts(
                handshake: .seconds(1),
                noteList: .milliseconds(120),
                pageList: .seconds(1),
                dataInfo: .seconds(1),
                dataPacket: .seconds(1)
            )
        )

        do {
            _ = try await session.run()
            XCTFail("expected the note list wait to time out")
        } catch let error as PenSessionError {
            XCTAssertEqual(error, .timedOut(step: .noteList))
        }

        XCTAssertTrue(transport.closed, "a timed-out session must close its transport")
    }

    func testCancellationFailsTheSessionAndClosesTheTransport() async throws {
        let transport = StalledPenTransport()
        let session = makeSession(transport: transport, timeouts: patientTimeouts)

        let task = Task { try await session.run() }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected the cancelled session to fail")
        } catch let error as PenSessionError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertTrue(transport.closed, "cancellation must close the transport")
        guard case .failed = session.state else {
            return XCTFail("a cancelled session must not report completion")
        }
    }

    func testRetryAfterPartialTransferStartsFromFreshState() async throws {
        let chunks = try sessionChunks()

        // Attempt one: the stream stops after one packet of the first note.
        let failed = FakePenTransport(
            chunks: [
                chunks.version,
                chunks.noteList,
                chunks.firstPageList,
                chunks.firstInfo,
                chunks.firstPackets[0]
            ]
        )
        let failedSession = makeSession(transport: failed)
        do {
            _ = try await failedSession.run()
            XCTFail("expected the partial transfer to fail")
        } catch let error as PenSessionError {
            XCTAssertEqual(error, .incompleteTransfer(assembledPacketCount: 1))
        }
        XCTAssertTrue(failed.closed, "the failed attempt's transport must be closed")

        // Retry: a new session over a new transport, with no buffered frame and
        // no partial transfer carried over from the failed attempt.
        let retried = FakePenTransport(chunks: try sessionFixture().decodedChunks())
        let retriedSession = makeSession(transport: retried)
        let result = try await retriedSession.run()

        XCTAssertEqual(retriedSession.state, .complete)
        XCTAssertEqual(result.strokeCount, 4)
        XCTAssertEqual(result.distinctPageCount, 4)
        XCTAssertEqual(result.notes.map(\.packetCount), [3, 1])
    }

    func testSessionRefusesASecondConcurrentRun() async throws {
        let transport = StalledPenTransport()
        let session = makeSession(transport: transport, timeouts: patientTimeouts)

        let first = Task { try await session.run() }
        try await Task.sleep(for: .milliseconds(50))

        do {
            _ = try await session.run()
            XCTFail("expected the second run to be refused")
        } catch let error as PenSessionError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        first.cancel()
        _ = try? await first.value
    }
}

/// Collects the states a session reports, in order.
private final class StateRecorder: Sendable {
    private let states = Mutex<[PenSessionState]>([])

    func record(_ state: PenSessionState) {
        states.withLock { $0.append(state) }
    }

    var all: [PenSessionState] {
        states.withLock { $0 }
    }
}
