import Foundation
import NeoBridgeMacCore
import Synchronization

/// A clock the automatic schedule can be moved by hand.
///
/// The schedule measures minutes between opportunities, so a test that used the
/// system clock would either wait for them or race them. This clock moves only
/// when a test says so, and it resolves the waits that have come due, which makes
/// "an interval elapsed" a statement a test makes rather than one it waits for.
final class FakePenSyncClock: PenSyncClock, @unchecked Sendable {
    /// One suspended wait.
    private struct Waiter {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Store {
        var now: ContinuousClock.Instant
        var waiters: [Waiter] = []
    }

    private let store: Mutex<Store>

    /// Creates a clock positioned at the system clock's current instant.
    init() {
        store = Mutex(Store(now: ContinuousClock.now))
    }

    var now: ContinuousClock.Instant { store.withLock { $0.now } }

    /// Moves the clock forward and resolves every wait that has come due.
    func advance(by duration: Duration) {
        let due: [Waiter] = store.withLock { state in
            state.now = state.now.advanced(by: duration)
            let ready = state.waiters.filter { $0.deadline <= state.now }
            state.waiters.removeAll { $0.deadline <= state.now }
            return ready
        }
        for waiter in due { waiter.continuation.resume() }
    }

    func wait(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let isDue = store.withLock { state -> Bool in
                    if state.now >= deadline { return true }
                    state.waiters.append(
                        Waiter(id: id, deadline: deadline, continuation: continuation)
                    )
                    return false
                }
                if isDue { continuation.resume() }
            }
        } onCancel: {
            let pending: Waiter? = store.withLock { state in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.waiters.remove(at: index)
            }
            pending?.continuation.resume(throwing: CancellationError())
        }
    }
}
