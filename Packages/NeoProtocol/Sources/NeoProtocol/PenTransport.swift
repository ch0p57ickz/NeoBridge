import Foundation
import Synchronization

/// The platform-neutral byte contract between the protocol codec and a pen
/// connection.
///
/// A `CoreBluetoothPenTransport` for the A1 belongs to the macOS app target and
/// adapts BLE callbacks to this contract. Keeping the contract free of platform
/// types is what lets the codec and its fixtures run on Linux.
public protocol PenTransport: Sendable {
    /// Returns the inbound byte chunks.
    ///
    /// The stream yields chunks in arrival order, finishes when the connection
    /// ends normally, and throws when the connection is interrupted.
    func receive() -> AsyncThrowingStream<[UInt8], any Error>

    /// Sends one outbound byte chunk.
    func send(_ bytes: [UInt8]) async throws

    /// Closes the connection.
    func close() async
}

/// A deterministic in-memory transport for tests and fixture replay.
///
/// The transport yields its scripted chunks in order and then either finishes or
/// throws the scripted failure, which models an interrupted sync. Every chunk
/// passed to `send(_:)` is recorded so a test can assert that no production
/// request was sent.
public final class FakePenTransport: PenTransport, Sendable {
    private struct State: Sendable {
        var outbound: [[UInt8]] = []
        var isClosed = false
    }

    private let inbound: [[UInt8]]
    private let failure: (any Error & Sendable)?
    private let state = Mutex(State())

    /// Creates a transport that yields the given chunks.
    ///
    /// - Parameters:
    ///   - chunks: Inbound chunks, delivered in order.
    ///   - failure: An error to throw after the chunks are delivered. Use it to
    ///     model a connection that drops mid-transfer.
    public init(chunks: [[UInt8]], failure: (any Error & Sendable)? = nil) {
        self.inbound = chunks
        self.failure = failure
    }

    /// Creates a transport that yields a single chunk.
    public convenience init(bytes: [UInt8], failure: (any Error & Sendable)? = nil) {
        self.init(chunks: [bytes], failure: failure)
    }

    /// Every chunk passed to `send(_:)`, in order.
    public var sentChunks: [[UInt8]] {
        state.withLock { $0.outbound }
    }

    /// Whether `close()` has been called.
    public var closed: Bool {
        state.withLock { $0.isClosed }
    }

    public func receive() -> AsyncThrowingStream<[UInt8], any Error> {
        let chunks = inbound
        let failure = failure

        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        state.withLock { $0.outbound.append(bytes) }
    }

    public func close() async {
        state.withLock { $0.isClosed = true }
    }
}
