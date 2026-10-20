import Foundation
import NeoProtocol

/// A transport that drops the link in the middle of an offline transfer.
///
/// The transfer-option experiment in `Tests/Hardware/README.md` needs an
/// interrupted transfer: the read must stop part way through a `0x24` stream so a
/// later read can prove that every stroke the host never imported is still on the
/// pen. This decorator is how a headless run does that on purpose instead of by
/// unplugging something.
///
/// It counts the `0x24` packets that arrive and, when the numbered one arrives,
/// stops forwarding: that packet is never delivered, so the session is left waiting
/// for a packet that never comes and fails as an incomplete transfer rather than as
/// a transport error — the failure a user sees when a pen walks out of range
/// mid-read.
///
/// The link is dropped by ``close()`` rather than inside the pump. The session is
/// still mid-conversation when the packet arrives: closing the transport right there
/// could fail a request the session is still sending, which would report
/// `notConnected` instead of the interrupted transfer the experiment is after. The
/// session closes the transport it was given as part of failing, so the pen is
/// released as soon as the host notices, and the pen itself stalls in the meantime
/// because its next packet is sent only after an acknowledgement the host never
/// sends.
///
/// The numbering counts packets that *arrived*, not packets that the session
/// assembled: the packet that triggers the abort is dropped, so a session over this
/// transport assembles one fewer packet than the number given when that packet is
/// the only frame its notification carried, which is what the A1 does. A
/// notification that also completed a later packet drops that one too, and the abort
/// line reports how many, so the transcript never overstates what the session
/// assembled. The counts are read from the frame decoder, so a packet split across
/// chunks still counts once.
///
/// The number must be positive. A non-positive one would abort on the first packet;
/// ``PenAcceptanceOptions`` refuses such a value, and the runner is this type's only
/// caller.
public final class PenAbortingTransport: PenTransport, Sendable {
    private let inner: any PenTransport
    private let abortAtPacket: Int
    private let log: PenTrafficLog?

    /// Creates an aborting transport.
    ///
    /// - Parameters:
    ///   - inner: The transport whose link is dropped.
    ///   - abortAtPacket: The 1-based number of the arriving `0x24` packet whose
    ///     arrival closes the link. The packet is not delivered.
    ///   - log: An optional transcript, so the abort is recorded with the traffic
    ///     it interrupted.
    public init(
        wrapping inner: any PenTransport,
        abortAtPacket: Int,
        log: PenTrafficLog? = nil
    ) {
        self.inner = inner
        self.abortAtPacket = abortAtPacket
        self.log = log
    }

    public func receive() -> AsyncThrowingStream<[UInt8], any Error> {
        let inner = self.inner
        let log = self.log
        let limit = self.abortAtPacket
        let (stream, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()

        // The wrapped stream is pulled by a pump task, as in
        // `PenTracingTransport`: `AsyncThrowingStream` cannot be mapped in place,
        // and the pump must stop forwarding once the link is dropped.
        let pump = Task {
            var decoder = PenFrameDecoder()
            var arrivedPackets = 0
            do {
                for try await chunk in inner.receive() {
                    if case .abort(let trigger, let laterPackets) = Self.inspect(
                        chunk,
                        decoder: &decoder,
                        arrived: &arrivedPackets,
                        limit: limit
                    ) {
                        var line =
                            "abort stopped the transfer when 0x24 packet \(trigger) arrived;"
                            + " that packet is not delivered"
                        if laterPackets > 0 {
                            line +=
                                ", and \(laterPackets) later complete packet(s) in the same"
                                + " notification were dropped with it"
                        }
                        log?.record(line)
                        break
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in pump.cancel() }

        return stream
    }

    public func send(_ bytes: [UInt8]) async throws {
        try await inner.send(bytes)
    }

    public func close() async {
        await inner.close()
    }

    /// What one chunk did to the packet count.
    private enum ChunkResult {
        /// The chunk does not complete the numbered packet, so it is delivered.
        case deliver

        /// The chunk completes the numbered packet, which is dropped.
        ///
        /// - Parameters:
        ///   - trigger: The number of the packet whose arrival aborts.
        ///   - laterPackets: Further complete `0x24` packets in the same chunk,
        ///     which the drop takes with it.
        case abort(trigger: Int, laterPackets: Int)
    }

    /// What this chunk means for the abort, counting frames rather than chunks.
    ///
    /// A frame can span chunks and, in principle, one chunk can carry several
    /// frames, so the count comes from the decoder's frame boundaries. The A1 sends
    /// a packet as a frame far larger than a notification, so a chunk normally
    /// completes at most one packet; when one does carry several, the count of the
    /// ones a drop would take with it is reported rather than assumed to be zero.
    private static func inspect(
        _ chunk: [UInt8],
        decoder: inout PenFrameDecoder,
        arrived: inout Int,
        limit: Int
    ) -> ChunkResult {
        var trigger: Int?
        var laterPackets = 0
        for outcome in decoder.ingest(chunk) {
            guard case .frame(let frame) = outcome, frame.command == .offlineDataRequest2 else {
                continue
            }
            arrived += 1
            if trigger != nil {
                laterPackets += 1
            } else if arrived >= limit {
                trigger = arrived
            }
        }
        guard let trigger else { return .deliver }
        return .abort(trigger: trigger, laterPackets: laterPackets)
    }
}
