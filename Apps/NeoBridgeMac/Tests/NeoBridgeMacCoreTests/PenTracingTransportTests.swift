import Foundation
import NeoBridgeMacCore
import NeoProtocol
import XCTest

/// Tests for the acceptance transcript and the transport decorator that fills it.
final class PenTracingTransportTests: XCTestCase {
    // MARK: - Forwarding

    func testForwardsInboundChunksInOrderAndRecordsTheirSizes() async throws {
        let log = PenTrafficLog()
        let transport = PenTracingTransport(
            wrapping: FakePenTransport(chunks: [[0x01, 0x02], [0x03]]),
            log: log
        )

        var received: [[UInt8]] = []
        for try await chunk in transport.receive() {
            received.append(chunk)
        }

        XCTAssertEqual(received, [[0x01, 0x02], [0x03]], "the decorator must not reorder chunks")
        XCTAssertTrue(log.contents().contains("inbound 2 bytes"))
        XCTAssertTrue(log.contents().contains("inbound 1 bytes"))
    }

    func testForwardsAStreamFailureUnchanged() async throws {
        let log = PenTrafficLog()
        let inner = FakePenTransport(chunks: [[0x01]], failure: TestTraceError.interrupted)
        let transport = PenTracingTransport(wrapping: inner, log: log)

        var thrown: (any Error)?
        do {
            for try await _ in transport.receive() {}
            XCTFail("expected the inner failure to be forwarded")
        } catch {
            thrown = error
        }

        XCTAssertEqual(thrown as? TestTraceError, .interrupted)
    }

    func testForwardsOutboundBytesToTheWrappedTransport() async throws {
        let log = PenTrafficLog()
        let inner = FakePenTransport(chunks: [])
        let transport = PenTracingTransport(wrapping: inner, log: log)

        let frame = try XCTUnwrap(PenRequest.versionInfo())
        try await transport.send(frame)

        XCTAssertEqual(inner.sentChunks, [frame], "the pen must receive exactly the recorded bytes")
    }

    func testCloseReachesTheWrappedTransport() async throws {
        let log = PenTrafficLog()
        let inner = FakePenTransport(chunks: [])
        let transport = PenTracingTransport(wrapping: inner, log: log)

        await transport.close()

        XCTAssertTrue(inner.closed)
    }

    // MARK: - Transcript

    func testRecordsEachOutboundFrameDecodedToItsCommand() async throws {
        let log = PenTrafficLog()
        let transport = PenTracingTransport(wrapping: FakePenTransport(chunks: []), log: log)

        try await transport.send(try XCTUnwrap(PenRequest.versionInfo()))
        try await transport.send(try XCTUnwrap(PenRequest.noteList()))
        try await transport.send(
            try XCTUnwrap(PenRequest.acknowledgement(packetID: 7, operation: .stop))
        )

        let contents = log.contents()
        XCTAssertTrue(contents.contains("command=0x01"))
        XCTAssertTrue(contents.contains("command=0x21"))
        XCTAssertTrue(contents.contains("command=0xA4"))
        XCTAssertEqual(log.outboundCommands, [.versionInfo, .offlineNoteListRequest, .responseOfflineData])
    }

    func testTranscriptCarriesTheTotalsAndTheOutboundCommandList() async throws {
        let log = PenTrafficLog()
        let transport = PenTracingTransport(wrapping: FakePenTransport(chunks: [[0xAA, 0xBB]]), log: log)
        try await transport.send(try XCTUnwrap(PenRequest.noteList()))
        for try await _ in transport.receive() {}

        let contents = log.contents()
        XCTAssertTrue(
            contents.contains(
                "totals outboundFrames=1 outboundBytes=9 inboundChunks=1 inboundBytes=2"
            )
        )
        XCTAssertTrue(contents.contains("outboundCommands 0x21"), "the deletion check reads this line")
    }

    func testTranscriptNeverCarriesADeletionCommandForARunThatDoesNotDelete() async throws {
        let log = PenTrafficLog()
        let transport = PenTracingTransport(wrapping: FakePenTransport(chunks: []), log: log)

        // The whole read path, minus the packets: version, list, page list, data
        // request, and one acknowledgement.
        let note = PenOfflineNote(section: 3, owner: 27, note: 700)
        for frame in [
            PenRequest.versionInfo(),
            PenRequest.noteList(),
            PenRequest.pageList(for: note),
            PenRequest.offlineData(for: note),
            PenRequest.acknowledgement(packetID: 1, operation: .next),
        ] {
            try await transport.send(try XCTUnwrap(frame))
        }

        let listed = log.contents().split(separator: "\n").last(where: { $0.hasPrefix("outboundCommands ") })
        let line = try XCTUnwrap(listed, "the transcript must list the outbound commands")
        XCTAssertFalse(line.contains("0x25"), "the run sent no note-deletion request")
        XCTAssertFalse(line.contains("0x27"), "the run sent no page-deletion request")
    }

    func testUnknownOutboundFramingIsStillRecorded() async throws {
        let log = PenTrafficLog()
        let transport = PenTracingTransport(wrapping: FakePenTransport(chunks: []), log: log)

        // A frame the evidence table does not classify cannot be encoded by the
        // session, but the transcript must still show what left the host if one
        // ever did.
        try await transport.send([0xC0, 0x00, 0xC1])

        XCTAssertTrue(log.contents().contains("command=unknown"))
        XCTAssertEqual(log.outboundCommands.count, 1)
        XCTAssertNil(log.outboundCommands[0])
    }

    func testWriteProducesAFileAndReplacesPreviousContents() async throws {
        let log = PenTrafficLog()
        let transport = PenTracingTransport(wrapping: FakePenTransport(chunks: []), log: log)
        try await transport.send(try XCTUnwrap(PenRequest.noteList()))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neobridge-trace-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("stale\n".utf8).write(to: url)
        try log.write(to: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.contains("stale"), "the transcript replaces the file")
        XCTAssertEqual(written, log.contents())
    }
}

/// A failure used to model an interrupted connection.
enum TestTraceError: Error, Hashable {
    case interrupted
}
