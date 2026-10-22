import Foundation

/// Runs the app's automatic sync: discovery at launch, a read when the pen
/// appears, and another at each saved interval.
///
/// The coordinator is the schedule, not the read. It decides *when* a read
/// starts and leaves every step of the read to ``PenSyncController``, so it never
/// talks to the pen's protocol and never decides whether a deletion is safe. A
/// saved Delete mode therefore only asks the controller for a deleting transfer;
/// the controller's own gates still decide whether one happens.
///
/// The radio runs one scan at a time, so the schedule stops its observation
/// before a read starts its bounded selection scan and resumes it afterwards.
/// That handoff is why the two scans exist as separate operations on
/// ``PenBluetoothCentral`` rather than as one stream with a flag.
///
/// Everything is main-actor isolated: the schedule decides, the controller
/// publishes, and both are read by the same views.
@MainActor
public final class PenSyncCoordinator {
    /// What ends one wait for an opportunity.
    private enum Opportunity: Sendable {
        /// A matching pen appeared, or was away long enough to count as new.
        case appearance

        /// The saved interval elapsed since the previous attempt began.
        case deadline

        /// A saved setting changed, so the wait is re-planned.
        case replan

        /// The observation ended without either, as when the adapter goes away.
        case stopped
    }

    /// The longest a pen may stay silent and still count as continuously present.
    ///
    /// The pen advertises in bursts, so a gap of a few seconds is normal. A gap
    /// this long is a pen that left, and its next advertisement is an appearance
    /// that may start a read at once instead of waiting for the interval.
    public static let defaultFreshnessWindow: Duration = .seconds(30)

    /// How long the schedule waits for the adapter to become ready before it
    /// observes anyway.
    ///
    /// CoreBluetooth reports `.unknown` until it has read the radio, and a scan
    /// started in that window reports nothing at all. The wait is bounded so a Mac
    /// with no adapter does not park the schedule: the opportunity proceeds and
    /// the read reports the adapter's own reason.
    public static let defaultAdapterReadyTimeout: Duration = .seconds(2)

    /// How often the adapter-ready wait looks again.
    private static let adapterReadyPollStep: Duration = .milliseconds(50)

    /// How long a pen is remembered before its entry is dropped.
    ///
    /// A pen that has been gone this long is an appearance again whatever the
    /// table says, so dropping it changes no decision. The bound is what keeps the
    /// table from growing across a long-running session of power-cycled pens.
    private static let penMemory: Duration = .seconds(3600)

    private let central: any PenBluetoothCentral
    private let controller: PenSyncController
    private let clock: any PenSyncClock
    private let freshnessWindow: Duration
    private let adapterReadyTimeout: Duration

    /// The running schedule, or `nil` when the app is not scheduling.
    private var scheduleTask: Task<Void, Never>?

    /// The observation's advertisements, or `nil` when no opportunity is waiting.
    private var observationTask: Task<Void, Never>?

    /// Where a waiting opportunity receives its trigger.
    private var opportunityContinuation: AsyncStream<Opportunity>.Continuation?

    /// Callers suspended until a saved setting changes.
    private var replanWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether a change arrived while nobody was waiting for one.
    private var pendingReplan = false

    /// When each recently seen pen last advertised.
    ///
    /// The pen's identifier is the ephemeral one CoreBluetooth assigns, so this
    /// table is only about the current session: a pen that reconnects under a new
    /// identifier is a pen the schedule has not seen, and its advertisement is an
    /// appearance.
    private var lastSeenAt: [UUID: ContinuousClock.Instant] = [:]

    /// When the previous attempt began, or `nil` before the first one.
    private var lastAttemptStart: ContinuousClock.Instant?

    /// When the schedule started, which is when the first interval is measured
    /// from.
    ///
    /// Measuring the first interval from launch rather than from the first read is
    /// what makes an absent pen a condition the app reports on: the opportunity
    /// runs, the read's own bounded scan finds nothing, and Connection Details says
    /// so instead of the app going quiet until a pen happens to appear.
    private var scheduleStart: ContinuousClock.Instant?

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - central: The adapter the schedule observes with. It is the same adapter
    ///     the read's runner uses, because the radio runs one scan at a time.
    ///   - controller: The controller the schedule starts reads on. Its saved mode
    ///     and interval are the settings the schedule follows.
    ///   - clock: The clock the schedule measures intervals with. The default is
    ///     the system clock; a test supplies one it can move.
    ///   - freshnessWindow: How long a pen may stay silent and still count as
    ///     present.
    ///   - adapterReadyTimeout: How long to wait for the adapter before observing.
    public init(
        central: any PenBluetoothCentral,
        controller: PenSyncController,
        clock: any PenSyncClock = ContinuousClock(),
        freshnessWindow: Duration = PenSyncCoordinator.defaultFreshnessWindow,
        adapterReadyTimeout: Duration = PenSyncCoordinator.defaultAdapterReadyTimeout
    ) {
        self.central = central
        self.controller = controller
        self.clock = clock
        self.freshnessWindow = freshnessWindow
        self.adapterReadyTimeout = adapterReadyTimeout
    }

    /// Starts the schedule, which discovers the pen and syncs without a click.
    ///
    /// Starting twice does nothing, so a caller may start the schedule from
    /// wherever it first knows the app is running.
    public func start() {
        guard scheduleTask == nil else { return }
        pendingReplan = false
        lastAttemptStart = nil
        lastSeenAt.removeAll()
        scheduleStart = clock.now
        controller.settingsDidChange = { [weak self] in
            self?.replan()
        }
        scheduleTask = Task { [weak self] in
            await self?.runSchedule()
        }
    }

    /// Stops the schedule and its observation.
    ///
    /// A read that is already in flight is left alone: Paused stops future
    /// attempts, and stopping the app is the same kind of statement. The read's
    /// own outcome still reaches the controller, so nothing it acknowledged is
    /// left half-reported. Releasing the controller's availability waiters is what
    /// ends a schedule parked behind that read, so stopping never leaves a
    /// continuation held by a read that has not settled.
    public func stop() async {
        scheduleTask?.cancel()
        scheduleTask = nil
        controller.settingsDidChange = nil
        pendingReplan = true
        resumeReplanWaiters()
        controller.releaseAvailabilityWaiters()
        await stopObservation()
    }

    /// Re-plans the schedule after a saved setting changed.
    ///
    /// The controller calls this through ``PenSyncController/settingsDidChange``,
    /// so a mode or interval change takes effect on the next opportunity rather
    /// than on the next launch.
    public func replan() {
        pendingReplan = true
        resumeReplanWaiters()
        opportunityContinuation?.yield(.replan)
    }

    // MARK: - The schedule

    /// Runs opportunities until the schedule is cancelled.
    private func runSchedule() async {
        while !Task.isCancelled {
            guard controller.syncMode.isAutomatic else {
                // Paused stops discovery and timers. An attempt already in flight
                // is not this loop's to cancel: the controller owns it.
                await stopObservation()
                await waitForReplan()
                continue
            }

            let opportunity = await waitForOpportunity(until: nextDeadline())
            if Task.isCancelled { break }

            switch opportunity {
            case .appearance, .deadline:
                await runAutomaticRead()
            case .replan, .stopped:
                continue
            }
        }

        await stopObservation()
    }

    /// When the next interval opportunity is due, or `nil` when the schedule has
    /// not started.
    ///
    /// The interval is measured from the previous attempt's start rather than from
    /// its end, so a read that outlasted the interval leaves the next opportunity
    /// already due: the ticks it missed coalesce into that one attempt instead of
    /// stacking up.
    private func nextDeadline() -> ContinuousClock.Instant? {
        guard let reference = lastAttemptStart ?? scheduleStart else { return nil }
        return reference + controller.syncInterval.duration
    }

    /// Waits for the pen to appear or for the interval to elapse.
    ///
    /// - Parameter deadline: When the interval opportunity is due, or `nil` when
    ///   no attempt has run yet and only an appearance can start one.
    /// - Returns: What ended the wait.
    private func waitForOpportunity(until deadline: ContinuousClock.Instant?) async -> Opportunity {
        if pendingReplan {
            pendingReplan = false
            return .replan
        }

        await waitForReadyAdapter()
        if Task.isCancelled { return .stopped }

        let (opportunities, continuation) = AsyncStream<Opportunity>.makeStream()
        opportunityContinuation = continuation
        defer {
            opportunityContinuation = nil
            continuation.finish()
        }

        await startObservation(yieldingTo: continuation)

        var timer: Task<Void, Never>?
        if let deadline {
            let clock = self.clock
            timer = Task {
                do {
                    try await clock.wait(until: deadline)
                } catch {
                    // The wait was cancelled, which means the opportunity ended
                    // for another reason.
                    return
                }
                continuation.yield(.deadline)
            }
        }
        defer { timer?.cancel() }

        for await opportunity in opportunities {
            return opportunity
        }
        return .stopped
    }

    /// Starts one automatic read and waits for it to settle.
    ///
    /// The observation is stopped first, because the radio cannot run both scans
    /// and the read's own selection scan is the one that has to report every match
    /// to decide whether the pen is ambiguous.
    private func runAutomaticRead() async {
        lastAttemptStart = clock.now
        await stopObservation()
        controller.readAutomatically()
        // Waiting here is what keeps a second attempt from starting while this one
        // is in flight, and what keeps a missed tick from stacking a second read on
        // top of a pen the user is still choosing between.
        await controller.waitUntilAvailable()
    }

    // MARK: - Observation

    /// Starts the continuous scan and feeds fresh appearances to the opportunity.
    private func startObservation(yieldingTo continuation: AsyncStream<Opportunity>.Continuation) async {
        await stopObservation()
        refreshPenMemory()

        let advertisements = central.observe()
        observationTask = Task { @MainActor [weak self] in
            do {
                for try await peripheral in advertisements {
                    guard let self else { return }
                    // The observation keeps running after it reports a fresh
                    // appearance, so the pens that advertised in the same window are
                    // all remembered. A second pen that was never noted would look
                    // like a new appearance on the next observation and start a read
                    // of its own.
                    if self.noteAdvertisement(peripheral) {
                        continuation.yield(.appearance)
                    }
                }
            } catch {
                // The adapter ended the scan, so this opportunity ends with it.
                // The schedule re-plans rather than reporting a missing radio as a
                // missing pen.
            }
            continuation.yield(.stopped)
        }
    }

    /// Stops the observation scan, if one is running.
    private func stopObservation() async {
        observationTask?.cancel()
        observationTask = nil
        await central.stopObservation()
    }

    /// Re-dates every remembered pen to now, and forgets the ones long gone.
    ///
    /// Re-dating at the *start* of observation is what keeps a read from looking
    /// like an absence: a read that outlasted the freshness window stopped the
    /// observation, so without this the pen it just read would look like one that
    /// left and came back, and its next advertisement would start an immediate
    /// second read.
    private func refreshPenMemory() {
        let now = clock.now
        lastSeenAt = lastSeenAt.compactMapValues { seen in
            now - seen >= Self.penMemory ? nil : now
        }
    }

    /// Records one advertisement and reports whether it is a fresh appearance.
    ///
    /// A pen the schedule has not seen is an appearance, which is what makes the
    /// first advertisement after launch start a read. A pen it has seen is an
    /// appearance only after the freshness window of silence, so a pen that stays
    /// in range is synced on the interval rather than on every advertisement.
    private func noteAdvertisement(_ peripheral: PenPeripheral) -> Bool {
        let now = clock.now
        let isFresh = lastSeenAt[peripheral.id].map { now - $0 >= freshnessWindow } ?? true
        lastSeenAt[peripheral.id] = now
        return isFresh
    }

    // MARK: - Adapter readiness

    /// Waits, bounded, for the adapter to become ready before observing.
    private func waitForReadyAdapter() async {
        guard !central.state.isReady else { return }
        let deadline = clock.now + adapterReadyTimeout
        while !central.state.isReady, clock.now < deadline {
            do {
                try await clock.wait(until: clock.now + Self.adapterReadyPollStep)
            } catch {
                return
            }
        }
    }

    // MARK: - Re-planning

    /// Suspends until a saved setting changes or the schedule stops.
    private func waitForReplan() async {
        if pendingReplan {
            pendingReplan = false
            return
        }
        await withCheckedContinuation { continuation in
            replanWaiters.append(continuation)
        }
    }

    /// Releases everyone waiting for a saved setting to change.
    private func resumeReplanWaiters() {
        let waiters = replanWaiters
        replanWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
