import Foundation
import NeoProtocol
import Synchronization

/// A transport that advances a scripted conversation as the session sends.
///
/// `FakePenTransport` emits every scripted chunk immediately, so it can check
/// acknowledgement bytes but cannot prove pacing. A physical A1 sends one data
/// packet per acknowledgement, so a test that cares about flow control needs a
/// transport that holds each response back until the frame that should precede
/// it arrives. That is what this transport does: it walks its exchanges in order
/// and only releases an exchange's chunks once the session has sent the frame
/// that exchange expects.
///
/// A send that does not match the next exchange, or a send with no exchange
/// left, fails the conversation: the transport records the mismatch and finishes
/// the inbound stream with an error, so the session cannot pass by accident.
final class ConversationPenTransport: PenTransport, Sendable {
    /// One request/response step of the conversation.
    struct Exchange: Sendable {
        /// The outbound frame this exchange expects first.
        ///
        /// `nil` releases the chunks without waiting for a send, which is how a
        /// test scripts traffic the pen sends unprompted.
        var expects: [UInt8]?

        /// The inbound chunks released once the expected frame arrives.
        var emits: [[UInt8]]

        init(expects: [UInt8]?, emits: [[UInt8]]) {
            self.expects = expects
            self.emits = emits
        }
    }

    /// A conversation failure.
    enum ConversationError: Error, Hashable, Sendable {
        /// The session sent a frame the script did not expect next.
        case unexpectedSend(expected: [UInt8]?, received: [UInt8])

        /// The session sent a frame after the script was exhausted.
        case unexpectedExtraSend(received: [UInt8])
    }

    private struct State: Sendable {
        var exchanges: [Exchange]
        var continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation?
        var sent: [[UInt8]] = []
        var failure: ConversationError?
        var isClosed = false

        /// Releases every leading exchange that does not wait for a send.
        mutating func releaseLeadingExchanges() -> [[UInt8]] {
            var chunks: [[UInt8]] = []
            while let exchange = exchanges.first, exchange.expects == nil {
                exchanges.removeFirst()
                chunks.append(contentsOf: exchange.emits)
            }
            return chunks
        }
    }

    private let state = Mutex(State(exchanges: []))

    /// Creates a transport that walks the given exchanges in order.
    init(exchanges: [Exchange]) {
        state.withLock { $0.exchanges = exchanges }
    }

    /// Every chunk the session sent, in order.
    var sentChunks: [[UInt8]] {
        state.withLock { $0.sent }
    }

    /// The conversation failure, when the session sent an unexpected frame.
    var failure: ConversationError? {
        state.withLock { $0.failure }
    }

    /// Whether `close()` has been called.
    var closed: Bool {
        state.withLock { $0.isClosed }
    }

    /// How many scripted exchanges are left.
    var remainingExchangeCount: Int {
        state.withLock { $0.exchanges.count }
    }

    func receive() -> AsyncThrowingStream<[UInt8], any Error> {
        AsyncThrowingStream { continuation in
            let outcome = state.withLock { state -> (leading: [[UInt8]], finished: Bool) in
                state.continuation = continuation
                let leading = state.releaseLeadingExchanges()
                return (leading, state.exchanges.isEmpty && state.failure == nil)
            }

            for chunk in outcome.leading {
                continuation.yield(chunk)
            }
            if outcome.finished {
                continuation.finish()
            }
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        enum Action: Sendable {
            case emit([[UInt8]], finished: Bool)
            case fail(ConversationError)
        }

        let action = state.withLock { state -> Action in
            state.sent.append(bytes)

            guard let exchange = state.exchanges.first else {
                let error = ConversationError.unexpectedExtraSend(received: bytes)
                state.failure = error
                return .fail(error)
            }
            if let expected = exchange.expects, expected != bytes {
                let error = ConversationError.unexpectedSend(expected: expected, received: bytes)
                state.failure = error
                return .fail(error)
            }

            state.exchanges.removeFirst()
            let chunks = exchange.emits + state.releaseLeadingExchanges()
            return .emit(chunks, finished: state.exchanges.isEmpty)
        }

        switch action {
        case .fail(let error):
            state.withLock { $0.continuation }?.finish(throwing: error)
            throw error
        case .emit(let chunks, let finished):
            let continuation = state.withLock { $0.continuation }
            for chunk in chunks {
                continuation?.yield(chunk)
            }
            if finished {
                continuation?.finish()
            }
        }
    }

    func close() async {
        let continuation = state.withLock { state -> AsyncThrowingStream<[UInt8], any Error>.Continuation? in
            state.isClosed = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.finish()
    }
}
