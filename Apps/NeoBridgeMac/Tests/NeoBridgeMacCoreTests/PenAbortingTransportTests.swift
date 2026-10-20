import Foundation
import NeoBridgeMacCore
import NeoProtocol
import XCTest

/// Tests for the transport that drops the pen link in the middle of a transfer.
///
/// The experiment that establishes whether a transfer option is incremental needs
/// an interrupted transfer, and this decorator is how a headless run produces one
/// without unplugging anything.
final class PenAbortingTransportTests: XCTestCase {
    private func packet(id: UInt16, position: OfflineTransferPosition) -> [UInt8] {
        FakePenFrames.offlineStrokePacket(packetID: id, transferPosition: position)
    }

    private func delivered(
        from transport: any PenTransport
    ) async throws -> [[UInt8]] {
        var chunks: [[UInt8]] = []
        for try await chunk in transport.receive() {
            chunks.append(chunk)
        }
        return chunks
    }

    func testDeliversEveryChunkWhenThePacketNeverArrives() async throws {
        let discovery = FakePenFrames.discoveryOnly()
        let first = packet(id: 1, position: .start)
        let second = packet(id: 2, position: .end)
        let inner = FakePenTransport(chunks: discovery + [first, second])
        let log = PenTrafficLog()
        let aborting = PenAbortingTransport(
            wrapping: inner,
            abortAtPacket: 3,
            log: log
        )

        let received = try await delivered(from: aborting)

        XCTAssertEqual(received, discovery + [first, second])
        XCTAssertFalse(inner.closed, "a transfer that never reaches the number keeps its link")
        XCTAssertFalse(log.contents().contains("abort stopped the transfer"))
    }

    func testStopsDeliveringTheArrivingPacketAndClosesWhenTheAttemptDoes() async throws {
        let discovery = FakePenFrames.discoveryOnly()
        let first = packet(id: 1, position: .start)
        let second = packet(id: 2, position: .middle)
        let inner = FakePenTransport(chunks: discovery + [first, second])
        let log = PenTrafficLog()
        let aborting = PenAbortingTransport(
            wrapping: inner,
            abortAtPacket: 2,
            log: log
        )

        let received = try await delivered(from: aborting)

        XCTAssertEqual(received, discovery + [first], "the arriving packet is never delivered")
        XCTAssertTrue(
            log.contents().contains("abort stopped the transfer when 0x24 packet 2 arrived"),
            "the transcript has to show why the transfer stopped"
        )

        // The close belongs to the caller that owns the attempt: the session closes
        // the transport it was given as part of failing, which is the moment the pen
        // is released. Closing inside the pump instead could fail a request the
        // session was still sending and report `notConnected` rather than an
        // interrupted transfer.
        XCTAssertFalse(inner.closed, "the abort alone does not drop the link")
        await aborting.close()
        XCTAssertTrue(inner.closed, "the attempt's own close reaches the pen")
    }

    /// The count comes from the frame decoder, so a packet split across chunks is
    /// one packet rather than one per chunk.
    func testCountsAPacketSplitAcrossChunksOnce() async throws {
        let discovery = FakePenFrames.discoveryOnly()
        let first = packet(id: 1, position: .start)
        let middle = first.count / 2
        let firstHead = Array(first[0..<middle])
        let firstTail = Array(first[middle...])
        let second = packet(id: 2, position: .end)
        let inner = FakePenTransport(chunks: discovery + [firstHead, firstTail, second])
        let aborting = PenAbortingTransport(wrapping: inner, abortAtPacket: 2)

        let received = try await delivered(from: aborting)

        // The split packet finished in its second chunk and was counted once, so the
        // abort waits for the next packet and stops there.
        XCTAssertEqual(received, discovery + [firstHead, firstTail])
        await aborting.close()
        XCTAssertTrue(inner.closed)
    }

    func testForwardsSendsAndCloseToTheWrappedTransport() async throws {
        let inner = FakePenTransport(chunks: [])
        let aborting = PenAbortingTransport(wrapping: inner, abortAtPacket: 1)

        try await aborting.send([0x21, 0x00, 0x00])
        await aborting.close()

        XCTAssertEqual(inner.sentChunks, [[0x21, 0x00, 0x00]])
        XCTAssertTrue(inner.closed)
    }

    /// A notification that carries more than the packet that triggers the abort
    /// drops the later packets with it, so the transcript has to say how many
    /// rather than let the record imply that only one was lost.
    ///
    /// The A1 sends a packet as a frame far larger than a notification, so this
    /// combination does not occur on the pen; the test pins what happens if it ever
    /// does, because the assembled count is the experiment's evidence.
    func testReportsLaterPacketsInTheSameChunkAsDropped() async throws {
        let discovery = FakePenFrames.discoveryOnly()
        let first = packet(id: 1, position: .start)
        // Two complete packets inside one chunk.
        let twoPackets = packet(id: 2, position: .middle) + packet(id: 3, position: .end)
        let inner = FakePenTransport(chunks: discovery + [first, twoPackets])
        let log = PenTrafficLog()
        let aborting = PenAbortingTransport(wrapping: inner, abortAtPacket: 2, log: log)

        let received = try await delivered(from: aborting)

        XCTAssertEqual(received, discovery + [first], "both packets in the chunk are dropped")
        let contents = log.contents()
        XCTAssertTrue(
            contents.contains("abort stopped the transfer when 0x24 packet 2 arrived"),
            "the trigger is named by its own number, not by how many arrived with it"
        )
        XCTAssertTrue(
            contents.contains("1 later complete packet(s) in the same notification"),
            "the transcript must not imply only one packet was lost"
        )
    }
}
