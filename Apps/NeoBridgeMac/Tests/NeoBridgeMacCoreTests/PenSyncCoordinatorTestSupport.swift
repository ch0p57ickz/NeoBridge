import Foundation
import NeoBridgeMacCore
import NeoCore
import Synchronization

/// A one-shot gate an attempt waits on until a test releases it.
///
/// The gate is cancellation-aware, so a schedule that stops while an attempt is
/// held still ends that attempt rather than leaving it parked.
final class AttemptGate: @unchecked Sendable {
    private struct Store {
        var isOpen = false
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    private let store: Mutex<Store>

    init(isOpen: Bool = false) {
        store = Mutex(Store(isOpen: isOpen))
    }

    /// Whether the gate has been opened.
    var isOpen: Bool { store.withLock { $0.isOpen } }

    /// Suspends until ``open()`` is called.
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let isAlreadyOpen = store.withLock { state -> Bool in
                    if state.isOpen { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if isAlreadyOpen { continuation.resume() }
            }
        } onCancel: {
            let pending = store.withLock { $0.waiters.removeValue(forKey: id) }
            pending?.resume(throwing: CancellationError())
        }
    }

    /// Releases every waiter, and lets later waiters through at once.
    func open() {
        let waiters = store.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.isOpen = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Records what the automatic schedule asked for, and can hold an attempt open.
///
/// The schedule's tests need to see how many reads it started, whether one is
/// still running, and which transfer each was asked for. Holding an attempt open
/// is what makes "no overlapping reads" and "a missed tick coalesces" testable
/// without racing a real clock.
final class CoordinatorRunnerRecorder: @unchecked Sendable {
    private struct Store {
        var starts = 0
        var intents: [PenDeletingReadIntent?] = []
    }

    private let store = Mutex(Store())

    /// The read a successful attempt returns.
    let read: PenReadResult

    /// The error a failed attempt throws, or `nil` for a successful one.
    let failure: (any Error & Sendable)?

    /// The gate each attempt waits on before it finishes.
    let gate: AttemptGate

    /// Creates a recorder.
    ///
    /// - Parameters:
    ///   - read: The read a successful attempt returns.
    ///   - failure: The error a failed attempt throws.
    ///   - holdsAttempts: Whether attempts wait for ``gate`` before finishing.
    init(
        read: PenReadResult = TestRead.result(strokes: [TestRead.stroke()]),
        failure: (any Error & Sendable)? = nil,
        holdsAttempts: Bool = false
    ) {
        self.read = read
        self.failure = failure
        self.gate = AttemptGate(isOpen: !holdsAttempts)
    }

    /// How many attempts have started.
    var startCount: Int { store.withLock { $0.starts } }

    /// The deleting-read intent each attempt was asked for, in order.
    var intents: [PenDeletingReadIntent?] { store.withLock { $0.intents } }

    /// Records one attempt.
    func begin(intent: PenDeletingReadIntent?) {
        store.withLock {
            $0.starts += 1
            $0.intents.append(intent)
        }
    }
}

/// A runner that records each attempt and returns a scripted outcome.
struct CoordinatorRunner: PenSyncRunning {
    let recorder: CoordinatorRunnerRecorder

    func run(
        deletingRead: PenDeletingReadIntent?,
        report: @escaping @Sendable (PenSyncStage) -> Void
    ) async throws -> PenReadResult {
        recorder.begin(intent: deletingRead)
        report(.scanning)
        try await recorder.gate.wait()
        if let failure = recorder.failure { throw failure }
        return recorder.read
    }
}

/// A runner that scans the adapter as a real transport's selection step does.
///
/// The radio runs one scan at a time, so a read that started while the schedule
/// was still observing would stop the read's own selection scan. Starting a scan
/// here is what makes the fake's event log show the handoff.
struct HandoffRunner: PenSyncRunning {
    let central: FakePenBluetoothCentral
    let read: PenReadResult

    func run(
        deletingRead: PenDeletingReadIntent?,
        report: @escaping @Sendable (PenSyncStage) -> Void
    ) async throws -> PenReadResult {
        report(.scanning)
        let advertisements = central.scan()
        var iterator = advertisements.makeAsyncIterator()
        _ = try await iterator.next()
        await central.stopScan()
        return read
    }
}

/// A runner that asks for a pen choice on its first attempt and settles afterwards.
///
/// An unanswered question is a state the schedule has to hold through — no second
/// read may start while it is open — so a test needs an attempt that ends in that
/// state and a later attempt that finishes. The recorder still counts both attempts
/// and holds the second one open, which is what the other schedule tests use it for.
struct ChoosingRunner: PenSyncRunning {
    let recorder: CoordinatorRunnerRecorder
    let candidates: [PenPeripheral]

    func run(
        deletingRead: PenDeletingReadIntent?,
        report: @escaping @Sendable (PenSyncStage) -> Void
    ) async throws -> PenReadResult {
        recorder.begin(intent: deletingRead)
        report(.scanning)

        guard recorder.startCount > 1 else {
            throw PenBluetoothError.multiplePensFound(
                advertisedName: CoreBluetoothPenTransport.advertisedName,
                candidates: candidates
            )
        }

        try await recorder.gate.wait()
        if let failure = recorder.failure { throw failure }
        return recorder.read
    }
}
