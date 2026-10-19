import Foundation
import NeoProtocol

/// A transport that records what another transport sends and receives.
///
/// The decorator is the only place that sees both halves of a live connection, so
/// it is where an acceptance run's transcript comes from. It forwards every call
/// unchanged: the bytes the pen receives are exactly the bytes the wrapped
/// transport sent, and the chunks the session decodes are exactly the chunks the
/// pen delivered.
public final class PenTracingTransport: PenTransport, Sendable {
    private let inner: any PenTransport
    private let log: PenTrafficLog

    /// Creates a tracing transport.
    ///
    /// - Parameters:
    ///   - inner: The transport to forward to.
    ///   - log: The transcript to record into.
    public init(wrapping inner: any PenTransport, log: PenTrafficLog) {
        self.inner = inner
        self.log = log
    }

    public func receive() -> AsyncThrowingStream<[UInt8], any Error> {
        let inner = self.inner
        let log = self.log
        let (stream, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()

        // The wrapped stream is pulled by a pump task rather than by the
        // consumer, because `AsyncThrowingStream` cannot be mapped in place. The
        // pump ends when the stream ends or when the consumer stops reading.
        let pump = Task {
            do {
                for try await chunk in inner.receive() {
                    log.recordInbound(chunk)
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
        log.recordOutbound(bytes)
        try await inner.send(bytes)
    }

    public func close() async {
        await inner.close()
    }
}
