import Foundation
import NeoProtocol
import Synchronization

/// A transport that yields its scripted chunks and then never ends its stream.
///
/// `FakePenTransport` finishes its stream after its chunks, so a wait that finds
/// nothing there reports a finished stream rather than a stalled pen. This
/// transport keeps the stream open, which is what a silent-but-still-connected
/// pen looks like, so a test can exercise the bounded waits and cancellation.
final class StalledPenTransport: PenTransport, Sendable {
    private struct State: Sendable {
        var sent: [[UInt8]] = []
        var isClosed = false
    }

    private let chunks: [[UInt8]]
    private let state = Mutex(State())

    init(chunks: [[UInt8]] = []) {
        self.chunks = chunks
    }

    /// Every chunk passed to `send(_:)`, in order.
    var sentChunks: [[UInt8]] {
        state.withLock { $0.sent }
    }

    /// Whether `close()` has been called.
    var closed: Bool {
        state.withLock { $0.isClosed }
    }

    func receive() -> AsyncThrowingStream<[UInt8], any Error> {
        let chunks = chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            // Deliberately never finishes: the pen is silent but connected.
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        state.withLock { $0.sent.append(bytes) }
    }

    func close() async {
        state.withLock { $0.isClosed = true }
    }
}
