/// A stable cursor over the transport's inbound chunks.
///
/// `AsyncThrowingStream.Iterator` is a struct whose `next()` is a mutating async
/// function. An actor cannot call one on its own stored property, because the
/// call suspends while the actor is reentrant and the compiler cannot prove the
/// property is not mutated twice. Holding the iterator in a class gives the
/// cursor a stable identity across suspensions so the owning actor can call it.
///
/// Only one task may advance the cursor at a time, and the owning channel
/// enforces that; see `PenFrameChannel.next()`. That single-owner invariant is
/// what makes the `@unchecked Sendable` conformance below sound: the channel
/// actor serializes every call, so the cursor's mutable iterator is never
/// reached from two tasks, and the type is never shared outside this file.
private final class PenChunkCursor: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<[UInt8], any Error>.Iterator

    init(stream: AsyncThrowingStream<[UInt8], any Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    /// The next inbound chunk, or `nil` when the stream ended.
    func next() async throws -> [UInt8]? {
        try await iterator.next()
    }
}

/// Decodes the transport's inbound chunks into frames, in arrival order.
///
/// The A1 splits a large `0x24` frame across BLE notifications, so framing has
/// to be stateful over the whole notification stream rather than per
/// notification. This channel keeps one `PenFrameDecoder` across every chunk, so
/// a frame delivered as two chunks still decodes.
///
/// The channel is an actor because a session reads from it inside a bounded
/// wait, and the wait's timeout branch runs in a second task. The actor
/// serializes those reads, and the `isReading` guard turns a second concurrent
/// read into an explicit error rather than a data race.
actor PenFrameChannel {
    private let cursor: PenChunkCursor
    private var decoder: PenFrameDecoder
    private var pending: [PenFrameDecodeOutcome] = []
    private var isReading = false

    init(stream: AsyncThrowingStream<[UInt8], any Error>, limits: FrameLimits = .default) {
        self.cursor = PenChunkCursor(stream: stream)
        self.decoder = PenFrameDecoder(limits: limits)
    }

    /// The next framing outcome, or `nil` when the inbound stream ended.
    ///
    /// - Throws: The transport's own error when the connection was interrupted,
    ///   or `PenSessionError.protocolFailure` when two readers raced. A session
    ///   reads one frame at a time, so the latter never happens in practice.
    func next() async throws -> PenFrameDecodeOutcome? {
        guard !isReading else {
            throw PenSessionError.protocolFailure(
                .malformedPayload(
                    command: .offlineDataRequest2,
                    reason: "the frame channel was read from two places at once"
                )
            )
        }
        isReading = true
        defer { isReading = false }

        while true {
            if !pending.isEmpty {
                return pending.removeFirst()
            }
            guard let chunk = try await cursor.next() else {
                return nil
            }
            // A chunk can carry no complete frame, in which case the decoder
            // keeps the partial frame and the loop pulls the next chunk.
            pending = decoder.ingest(chunk)
        }
    }
}
