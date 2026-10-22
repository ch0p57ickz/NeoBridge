import Foundation

/// The clock the automatic sync schedule measures its intervals with.
///
/// Injecting the clock is what lets the schedule be tested without waiting for
/// minutes to pass: a test's clock moves forward only when the test says so. The
/// app's own schedule uses ``ContinuousClock``, whose waits are cancellation-aware.
public protocol PenSyncClock: Sendable {
    /// The current instant.
    var now: ContinuousClock.Instant { get }

    /// Suspends until `deadline` arrives.
    ///
    /// - Throws: `CancellationError` when the wait is cancelled.
    func wait(until deadline: ContinuousClock.Instant) async throws
}

extension ContinuousClock: PenSyncClock {
    public func wait(until deadline: ContinuousClock.Instant) async throws {
        try await sleep(until: deadline, tolerance: nil)
    }
}
