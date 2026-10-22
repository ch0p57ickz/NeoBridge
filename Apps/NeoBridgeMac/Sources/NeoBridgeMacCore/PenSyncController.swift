import Foundation
import NeoCore
import NeoProtocol
import Observation

/// Drives one read attempt and publishes what the shell shows.
///
/// The controller owns the attempt lifecycle — start, cancel, retry — and no
/// protocol, storage, or file logic. It reads one runner per attempt from its
/// factory, so every retry starts a new scan and a new session, and it hands the
/// complete transfer to the library, so a read is saved rather than summarized.
@MainActor
@Observable
public final class PenSyncController {
    /// What the shell is showing.
    public enum Phase: Hashable, Sendable {
        /// No attempt has started, or the user cancelled one.
        case idle

        /// Scanning for a pen advertising the expected name.
        case scanning

        /// Sending the version request and awaiting its response.
        case connecting

        /// Checking the reported protocol version.
        case verifying

        /// Discovering notes and reading their offline data.
        case syncing

        /// Committing the read to the library.
        case saving

        /// Publishing the read's page files.
        case exporting

        /// Several pens advertised the expected name, so the user chooses one.
        ///
        /// No pen is picked silently, and no candidate carries an address.
        case choosingPen(candidates: [PenPeripheral])

        /// The read finished. The outcome says whether it was stored and whether
        /// every requested file was written.
        case complete(PenReadOutcome)

        /// A step failed. `diagnostic` describes partial data when a transfer
        /// stopped early, and is never presented as a completed sync.
        case failed(message: String, diagnostic: String?)

        /// Whether the attempt has stopped and will do no more work.
        public var isTerminal: Bool {
            switch self {
            case .complete, .failed: return true
            case .idle, .scanning, .connecting, .verifying, .syncing, .saving, .exporting,
                .choosingPen:
                return false
            }
        }
    }

    /// The compact status the menu shows in one line.
    ///
    /// The menu is a control surface, so its status says only what a glance needs:
    /// whether a read is running, whether the last one stored anything, and whether
    /// the pen was there to be read. Counts, export paths, cleanup explanations, and
    /// failure detail stay in Connection Details.
    public enum MenuStatus: Hashable, Sendable {
        /// A read is running, or the app is waiting for the pen choice it asked for.
        case syncing

        /// The saved mode is Pause, so no pen is discovered and no read starts.
        case paused

        /// No attempt has settled yet.
        case idle

        /// The last read completed, at the given time.
        ///
        /// A read that carried no strokes counts as completed: the pen was reached
        /// and read, it simply had nothing new to store, so the sync did happen. That
        /// is what separates this case from ``notDetected``, where the pen was never
        /// there at all.
        ///
        /// The time is wall-clock rather than the schedule's clock, because the line
        /// reads as an elapsed time for a person: "Synced 5 minutes ago".
        case synced(at: Date)

        /// The last attempt found no pen advertising the expected name.
        case notDetected

        /// The last attempt failed for a reason other than a missing pen.
        case failed
    }

    /// The title of the action that retrieves offline strokes.
    ///
    /// The label says the app saves the pen's data, because that is what the read
    /// does now: the strokes are committed to the library and the requested files
    /// are written.
    public static let readActionTitle = "Read and Save Pen Data"

    /// The title of the action that publishes a stored read again.
    public static let retryExportActionTitle = "Retry Export"

    /// The title of the action that keeps the pen's copy for the current read.
    public static let retainPenDataTitle = "Keep Strokes on the Pen for This Read"

    /// The title of the action that confirms cleanup for one read.
    public static let confirmCleanupTitle = "Remove Acknowledged Packets for This Read"

    /// What the shell says before a deleting transfer about the pen's copy.
    ///
    /// The statement is about the deleting route the user is confirming, so it
    /// names the order that makes the route safe: a packet is removed as the read
    /// progresses, and only after the library has stored it. Publication comes
    /// afterwards, so a failed export is retried from the library rather than
    /// from the pen.
    public static let cleanupIntentStatement =
        "If you confirm cleanup for this read, each packet saved to the local library is removed"
        + " from the pen when the read acknowledges it. The files requested for this read are"
        + " exported afterwards; if that export fails, retry it from the local library."

    /// What the saved Sync and Delete mode does with the pen's copy.
    ///
    /// The statement is about the saved setting rather than about one read, so it
    /// names the gates that still apply: the mode authorizes an eligible automatic
    /// read, and it never stands in for evidence, a requested export, a matching pen
    /// identity, or a writable library.
    public static let automaticCleanupStatement =
        "Sync and Delete removes each packet saved to the local library from the pen when the read"
        + " acknowledges it. A read that requests no export, lacks safe transfer evidence, meets a"
        + " different pen, or has no writable library keeps the pen's copy instead, and Connection"
        + " Details names the reason."

    /// What the shell is showing now.
    ///
    /// Every write goes through ``setPhase(_:)``, which is what releases the
    /// automatic schedule when a read stops being in flight.
    public private(set) var phase: Phase = .idle

    /// How the last read ended, once it stopped being in flight.
    private enum AttemptResult: Hashable, Sendable {
        /// The read completed, at the given time.
        ///
        /// A read that carried no strokes still completed, so this case covers it:
        /// the pen was reached and read. Only a pen that was never there is
        /// ``notDetected``.
        case completedRead(at: Date)

        /// The attempt found no pen advertising the expected name.
        case notDetected

        /// The attempt failed for a reason other than a missing pen.
        case failed
    }

    /// The last read attempt's result, or `nil` before one settles.
    ///
    /// Only a read records here. An export retry republishes a read that already
    /// completed, so it leaves the status alone whether it succeeds or fails: the
    /// line answers "when did the pen last sync", not "when was a file last
    /// written". A cancelled attempt records nothing either, so the previous status
    /// stays on show: the user withdrew that read rather than the pen failing to
    /// appear.
    private var lastAttemptResult: AttemptResult?

    /// The compact status the menu shows.
    ///
    /// An attempt in flight wins over the saved mode, so pausing during a read
    /// still reports that read rather than claiming nothing is running; the mode
    /// item's own checkmark is what says the schedule is paused. Otherwise the
    /// saved mode wins over the last result, because a paused app is not syncing
    /// whatever the previous attempt did.
    public var menuStatus: MenuStatus {
        if isBusy || isAwaitingChoice { return .syncing }
        guard syncMode.isAutomatic else { return .paused }
        switch lastAttemptResult {
        case .completedRead(let date): return .synced(at: date)
        case .notDetected: return .notDetected
        case .failed: return .failed
        case nil: return .idle
        }
    }

    /// The measured state from the current completed read, if available.
    public var penState: PenState? { outcome?.penState }

    /// The cleanup intent the shell shows, which is the one the next transfer uses.
    ///
    /// It is the read in flight's intent while one runs, the completed read's intent
    /// while its files can still be published again — so a retry finishes that read
    /// with the intent it was given — and the next read's intent at every other
    /// moment. Every choice the shell offers is honoured by whoever uses it.
    public var cleanupIntent: PenCleanupMode {
        if isBusy || isRetryableCompletion { return attemptCleanupMode }
        return nextReadCleanupMode
    }

    /// The intent the next read will use.
    ///
    /// It starts at the policy's default, which is cleanup. A choice made while no
    /// read is in flight replaces it, and the read that consumes it restores the
    /// default, so no stale choice is inherited by a later sync.
    private var nextReadCleanupMode: PenCleanupMode

    /// The intent the read in flight, or the completed read a retry can still
    /// finish, uses.
    ///
    /// It is captured when the read starts, so the value the read requested cannot
    /// change while it runs, and it is what its own retry uses unless the user
    /// chooses otherwise.
    private var attemptCleanupMode: PenCleanupMode

    /// Whether the phase is a completed read whose files a retry can still publish.
    private var isRetryableCompletion: Bool {
        if case .complete = phase { return canRetryExport }
        return false
    }

    private let runners: PenSyncRunnerFactory
    private let library: any PenImportCoordinator
    private let destination: any PenExportDestinationProviding
    private let cleanupPolicy: PenCleanupPolicy
    private let deletingReadStorage: PenDeletingReadStorage
    private var attempt: Task<Void, Never>?
    private var generation = 0

    /// Where the saved sync settings are read from and written to.
    ///
    /// It is `nil` for a controller a caller drives directly rather than through
    /// the automatic schedule: the headless acceptance run and the shell tests.
    /// Such a controller has no saved setting to honor, so its transfer is
    /// authorized by the per-read confirmation instead.
    private let preferences: PenSyncPreferences?

    /// Called after a saved setting changes, so the automatic schedule can re-plan.
    public var settingsDidChange: (@MainActor () -> Void)?

    /// The saved mode the automatic schedule follows.
    ///
    /// It is published so the menu and the window can show a checkmark beside the
    /// saved setting, and so a test can read back what a selection saved.
    public private(set) var syncMode: PenSyncMode

    /// The saved interval the automatic schedule follows.
    public private(set) var syncInterval: PenSyncInterval

    /// Waiters that are suspended until no read is in flight and no pen choice is
    /// pending.
    private var availabilityWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether the next read has this sync's cleanup confirmation.
    ///
    /// It is deliberately not durable: a confirmation applies to one read, so a
    /// later sync starts unconfirmed and must ask again.
    private var nextReadCleanupConfirmed = false

    /// Whether the read in flight was confirmed for cleanup.
    private var attemptCleanupConfirmed = false

    /// Creates a controller.
    ///
    /// - Parameters:
    ///   - runners: The factory that makes a runner for each attempt.
    ///   - library: The verified importer that stores a read and publishes it.
    ///   - destination: The folder exports are written to.
    ///   - cleanupPolicy: The pen cleanup policy. Its mode is the intent a sync
    ///     that makes no choice gets, and its two evidence records decide whether
    ///     the command gate or the deleting-transfer route is open.
    ///   - deletingReadStorage: The durable packet storage a deleting read commits
    ///     through. The default has none, so a deleting read is refused rather
    ///     than started without a barrier.
    ///   - preferences: The saved sync settings, or `nil` for a controller that is
    ///     driven directly and has no saved setting to honor. The app supplies a
    ///     store; the headless acceptance run and the shell tests do not.
    public init(
        runners: PenSyncRunnerFactory,
        library: any PenImportCoordinator,
        destination: any PenExportDestinationProviding,
        cleanupPolicy: PenCleanupPolicy = PenCleanupPolicy(),
        deletingReadStorage: PenDeletingReadStorage = .unavailable,
        preferences: PenSyncPreferences? = nil
    ) {
        self.runners = runners
        self.library = library
        self.destination = destination
        self.cleanupPolicy = cleanupPolicy
        self.deletingReadStorage = deletingReadStorage
        self.preferences = preferences
        self.syncMode = preferences?.mode ?? .delete
        self.syncInterval = preferences?.interval ?? .fiveMinutes
        self.nextReadCleanupMode = cleanupPolicy.mode
        self.attemptCleanupMode = cleanupPolicy.mode
    }

    // MARK: - Saved settings

    /// Saves the sync mode the automatic schedule follows.
    ///
    /// Selecting Delete or Retain while Paused is what resumes automatic sync, so
    /// the change is reported to the schedule rather than only stored. A mode set
    /// while a read is in flight is saved and applies to the next read: the read
    /// already captured its own transfer, so changing it here cannot change what
    /// that read does.
    ///
    /// - Parameter mode: The setting the user selected.
    public func selectSyncMode(_ mode: PenSyncMode) {
        guard mode != syncMode else { return }
        syncMode = mode
        preferences?.mode = mode
        settingsDidChange?()
    }

    /// Saves the interval the automatic schedule follows.
    ///
    /// - Parameter interval: The setting the user selected.
    public func selectSyncInterval(_ interval: PenSyncInterval) {
        guard interval != syncInterval else { return }
        syncInterval = interval
        preferences?.interval = interval
        settingsDidChange?()
    }

    /// A one-line statement of what the saved mode means for the pen's copy, for
    /// Connection Details.
    public var syncModeLine: String {
        switch syncMode {
        case .delete:
            return "Each eligible automatic sync removes the packets it saved from the pen."
        case .retain:
            return "Automatic syncs read the pen and keep its copy."
        case .paused:
            return "Automatic sync is paused. No pen is discovered and no read starts."
        }
    }

    /// A one-line statement of the saved interval, for Connection Details.
    public var syncIntervalLine: String {
        "Another automatic sync is offered every \(syncInterval.title) while the pen is available."
    }

    // MARK: - Availability

    /// Suspends until no read is in flight and no pen choice is pending.
    ///
    /// The automatic schedule waits on this after it asks for a read, so it never
    /// starts a second read and never stacks opportunities while the user answers a
    /// question about which pen to use.
    public func waitUntilAvailable() async {
        guard isBusy || isAwaitingChoice else { return }
        await withCheckedContinuation { continuation in
            availabilityWaiters.append(continuation)
        }
    }

    /// Releases everyone suspended in ``waitUntilAvailable()``.
    ///
    /// The automatic schedule calls this when it stops, so a schedule parked behind
    /// a read that never settles does not hold a continuation forever. Releasing the
    /// wait does not cancel the read: a caller that is still wanted simply waits
    /// again, and one that is not checks whether it should carry on.
    func releaseAvailabilityWaiters() {
        let waiters = availabilityWaiters
        availabilityWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Whether a deleting transfer can be offered for a prospective read.
    ///
    /// The deleting route needs a requested export, version-matched
    /// transfer evidence, and durable packet storage. The per-sync confirmation is
    /// separate: this says the route is available, and
    /// ``isCleanupConfirmedForThisSync`` says whether it is confirmed.
    public var isCleanupAvailable: Bool { cleanupUnavailableReason == nil }

    /// Why a deleting transfer cannot be offered, or `nil` when it can.
    ///
    /// The reason names the transfer-specific blocker rather than the closed
    /// `0x25` command scope, because the deleting route does not use that command.
    public var cleanupUnavailableReason: String? {
        guard destination.exportDirectory() != nil else {
            return PenDeletingReadRefusal.noExportRequested.reason
        }
        guard deletingReadStorage.isAvailable else {
            return PenDeletingReadRefusal.durableStorageUnavailable(
                reason: deletingReadStorage.unavailableReason ?? "no writable library is available"
            ).reason
        }
        guard cleanupPolicy.transferEvidence.isSafe else {
            return cleanupPolicy.transferEvidence.refusal(
                for: cleanupPolicy.transferEvidence.identity
                    ?? PenDeletingTransferIdentity.physicalA1_2026_10_21
            )
        }
        return nil
    }

    /// Whether the current sync intends to reclaim the pen's copy.
    public var isCleanupIntended: Bool { cleanupIntent == .deleteAfterAcknowledge }

    /// Whether the shell must still ask for this sync's cleanup confirmation.
    ///
    /// A completed read whose files a retry can still publish needs none: the retry
    /// only publishes from the library and removes nothing, so a confirmation would
    /// authorize nothing and offering the button would offer a control that does
    /// nothing.
    public var needsCleanupConfirmation: Bool {
        guard isCleanupIntended, isCleanupAvailable, canChooseCleanup else { return false }
        guard !isRetryableCompletion else { return false }
        return !isCleanupConfirmedForThisSync
    }

    /// Whether the sync the shell shows is confirmed for a deleting transfer.
    public var isCleanupConfirmedForThisSync: Bool {
        if isBusy || isRetryableCompletion { return attemptCleanupConfirmed }
        return nextReadCleanupConfirmed
    }

    /// Confirms cleanup for one read.
    ///
    /// The confirmation is what authorizes the deleting route for the read it is
    /// made against, and it is cleared when that read starts, so a later sync
    /// cannot inherit it.
    public func confirmCleanupForThisSync() {
        guard canChooseCleanup, isCleanupAvailable, isCleanupIntended else { return }
        if isRetryableCompletion {
            // A retry only publishes from the library, so a confirmation would
            // authorize nothing.
            return
        }
        nextReadCleanupConfirmed = true
    }

    /// Whether the shell offers a cleanup choice.
    ///
    /// A choice made while a read is in flight would not reach that read, which
    /// captured its intent when it started, so only that state withholds the choice.
    /// A completed deleting read whose files a retry can still publish withholds it
    /// too: that read removed the packets it stored as it went, so a retry only
    /// republishes the durable copy and there is nothing left for a choice to keep or
    /// remove. Every other offered choice is honoured: the retry of an ordinary
    /// completed read uses the one made for it, and the next read uses any other.
    public var canChooseCleanup: Bool {
        if isBusy { return false }
        return !isRetryableDeletingCompletion
    }

    /// Whether the completion shown is a deleting read a retry can still publish.
    private var isRetryableDeletingCompletion: Bool {
        if case .complete(let outcome) = phase {
            return canRetryExport && outcome.isDeletingRead
        }
        return false
    }

    /// A one-line statement of the intent the shell is showing.
    ///
    /// It names what the choice applies to, because that differs: a read that is
    /// running already captured its intent and confirmation, a completed read
    /// whose files can still be published again hands the choice to its retry,
    /// and every other moment hands it to the next read. A retry never deletes, so
    /// its line says so.
    public var cleanupIntentLine: String {
        if isBusy {
            guard isCleanupIntended else {
                return "Keeping the pen's strokes for this read."
            }
            return attemptCleanupConfirmed
                ? "Removing each acknowledged packet from the pen as this read progresses."
                : "Keeping the pen's strokes for this read; cleanup was not confirmed."
        }
        if isRetryableCompletion {
            return "Retry Export publishes files from the library and removes nothing from the pen."
        }
        guard isCleanupIntended else {
            return "The next read keeps the pen's strokes."
        }
        guard isCleanupAvailable else {
            return "The next read keeps the pen's strokes because cleanup is unavailable."
        }
        return isCleanupConfirmedForThisSync
            ? "The next read removes each acknowledged packet after the library stores it."
            : "The next read can remove acknowledged packets once you confirm cleanup for it."
    }

    /// Chooses retention.
    ///
    /// A choice made while a read is running would not reach that read, so it is
    /// ignored rather than silently applied to the next one.
    public func retainPenDataForThisSync() {
        chooseCleanupIntent(.keepOnPen)
    }

    /// Chooses cleanup.
    public func intendCleanupForThisSync() {
        chooseCleanupIntent(.deleteAfterAcknowledge)
    }

    /// Applies a choice to the transfer the shell shows it against.
    ///
    /// A choice made while a completed read can still be published again belongs to
    /// that retry; at every other moment it belongs to the next read.
    private func chooseCleanupIntent(_ mode: PenCleanupMode) {
        guard !isBusy else { return }
        if isRetryableCompletion {
            attemptCleanupMode = mode
        } else {
            nextReadCleanupMode = mode
        }
    }

    /// Whether an attempt is running.
    public var isBusy: Bool {
        switch phase {
        case .scanning, .connecting, .verifying, .syncing, .saving, .exporting: return true
        case .idle, .choosingPen, .complete, .failed: return false
        }
    }

    /// Whether the app is waiting for the user to choose between pens.
    public var isAwaitingChoice: Bool {
        if case .choosingPen = phase { return true }
        return false
    }

    /// The pens that matched, when the app is waiting for a choice.
    public var penCandidates: [PenPeripheral] {
        if case .choosingPen(let candidates) = phase { return candidates }
        return []
    }

    /// A short status line for the menu and the window.
    public var statusLabel: String {
        switch phase {
        case .idle: return "Idle"
        case .scanning: return PenSyncStage.scanning.label
        case .connecting: return PenSyncStage.connecting.label
        case .verifying: return PenSyncStage.verifying.label
        case .syncing: return PenSyncStage.syncing.label
        case .saving: return "Saving to the library"
        case .exporting: return "Writing export files"
        case .choosingPen: return "Choose a pen"
        case .complete(let outcome):
            // A deleting read with no durably recorded completion is not a completed
            // sync: what it holds is the durable prefix it acknowledged. The notice
            // names whether the transfer stopped short or its completion could not be
            // recorded.
            return outcome.isPartialDeletingRead ? "Partial" : "Complete"
        case .failed: return "Failed"
        }
    }

    /// The finished read, when the attempt succeeded.
    public var outcome: PenReadOutcome? {
        if case .complete(let outcome) = phase { return outcome }
        return nil
    }

    /// The failure message, when the attempt failed.
    public var errorMessage: String? {
        if case .failed(let message, _) = phase { return message }
        return nil
    }

    /// The partial-data diagnostic for a failed attempt, when there is one.
    public var errorDiagnostic: String? {
        if case .failed(_, let diagnostic) = phase { return diagnostic }
        return nil
    }

    /// The folder exports are written to, or `nil` when none has been chosen.
    public var exportDirectoryPath: String? {
        destination.exportDirectory()
    }

    /// Whether a stored read can have its files published again.
    ///
    /// The retry is offered only while the completed read is the one shown, so a
    /// later failed attempt cannot leave a Retry action that republishes an older
    /// read and reports it as the current result.
    public var canRetryExport: Bool {
        guard case .complete(let outcome) = phase else { return false }
        return outcome.canRetryExport && outcome.exportFailed
    }

    /// Stores the folder the user chose.
    ///
    /// - Parameter url: The chosen folder.
    /// - Throws: When the folder cannot be remembered, so the app never claims a
    ///   destination it cannot reopen.
    public func chooseExportDirectory(_ url: URL) throws {
        try destination.setExportDirectory(url)
    }

    /// Starts a read attempt that a caller drives directly.
    ///
    /// This is the headless acceptance run's entry point and the shell tests'
    /// entry point. The saved mode does not apply: the transfer is authorized only
    /// by the per-read intent and confirmation, so a run that asks for cleanup
    /// without confirming it keeps the pen's copy. The app's automatic syncs use
    /// ``readAutomatically()`` instead, where the saved mode is what authorizes the
    /// transfer.
    ///
    /// A call while a choice is pending does nothing, so a read cannot skip the
    /// question about which pen to use.
    public func readPenData() {
        guard !isAwaitingChoice else { return }
        start(selection: .automatic, authorization: .perReadChoice)
    }

    /// Starts one automatic sync, authorized by the saved mode.
    ///
    /// The saved mode is what authorizes this read: Sync and Delete asks for a
    /// deleting transfer without a further click, Sync and Retain asks for the
    /// ordinary non-destructive read, and Paused starts nothing. The transfer's own
    /// gates — a requested export, safe evidence, a matching pen identity, and
    /// durable packet storage — still decide whether deletion can happen, so the
    /// mode never stands in for them.
    ///
    /// A read already in flight, or a pen choice waiting to be answered, keeps this
    /// call from starting a second read.
    public func readAutomatically() {
        guard syncMode.isAutomatic else { return }
        guard !isAwaitingChoice, !isBusy else { return }
        start(selection: .automatic, authorization: .savedMode)
    }

    /// Reads the pen the user chose after several matched.
    ///
    /// The intent the user set, the confirmation given for it, and the saved mode
    /// the read was authorized by all survive the question, because the attempt had
    /// not started when they were asked. Answering a question resumes the read that
    /// asked it rather than starting a new one under a different authorization.
    ///
    /// - Parameter peripheral: A candidate from ``penCandidates``.
    public func choosePen(_ peripheral: PenPeripheral) {
        guard isAwaitingChoice else { return }
        start(selection: .explicit(peripheral), authorization: attemptAuthorization)
    }

    /// Stops the running attempt and returns to idle.
    ///
    /// The published phase is set at once and the attempt's generation is
    /// retired, so a late callback from the cancelled attempt cannot overwrite
    /// this state or report a completion.
    public func cancel() {
        guard isBusy || isAwaitingChoice else { return }
        attempt?.cancel()
        settle()
        // The cancelled sync consumed its choice and confirmation, so the next
        // read starts from the policy's default again.
        nextReadCleanupMode = cleanupPolicy.mode
        nextReadCleanupConfirmed = false
        generation += 1
        setPhase(.idle)
    }

    /// Publishes the last stored read's files again.
    ///
    /// The retry reads the committed rows, so it never imports the read twice and
    /// never invents a result from data that was not stored. A retry that completes
    /// the publication finishes the same read, so it requests cleanup for the
    /// intent the shell is showing: the displayed intent is the one that is used,
    /// so a retention choice made after a failed export is honoured here instead
    /// of being discarded.
    public func retryExport() {
        guard canRetryExport, case .complete(let outcome) = phase, let save = outcome.save,
            let directory = outcome.destinationDirectory
        else { return }

        generation += 1
        let generation = self.generation
        // The retry finishes the read that is shown, so it uses the intent the shell
        // is showing for it: the read's own intent, or a choice made at the end of
        // that read. Capturing it keeps the value fixed even if the shell is tapped
        // again while the retry runs.
        let mode = cleanupIntent
        setPhase(.exporting)

        let request = PenExportRequest(pages: save.pages, destinationDirectory: directory)
        attempt = Task { [weak self] in
            guard let controller = self else { return }
            do {
                let report = try await controller.library.retryExport(
                    batchID: save.batchID,
                    request: request
                )
                // A cancelled retry stops here: the user ended this sync, so nothing
                // more may reach the pen for it.
                guard controller.generation == generation else { return }

                let cleanup: PenCleanupOutcome
                if outcome.isDeletingRead {
                    // A deleting batch is never the subject of a separate deletion
                    // command, so the retry only republishes its files and the
                    // read's own transfer outcome stands.
                    cleanup = outcome.cleanup
                } else if report.succeeded, mode == .deleteAfterAcknowledge,
                    controller.attemptAuthorization == .savedMode
                {
                    // An automatic Sync and Delete read removes packets only
                    // through its deleting transfer, so its retry republishes from
                    // the library and asks for no separate deletion command either.
                    cleanup = .skipped(reason: controller.automaticCleanupRefusal)
                } else if report.succeeded {
                    cleanup = await controller.requestCleanup(for: save.batchID, mode: mode)
                } else if mode == .keepOnPen {
                    // The retry did not publish, so no deletion was requested and
                    // the retention the user chose still stands for this read.
                    cleanup = .retainedByChoice
                } else {
                    // The pen's copy is where the read left it, so its outcome stands.
                    cleanup = outcome.cleanup
                }
                controller.finishRetry(
                    with: report,
                    cleanup: cleanup,
                    for: generation,
                    base: outcome
                )
            } catch {
                controller.fail(with: error, for: generation)
            }
        }
    }

    // MARK: - Attempt

    /// Where a read's transfer authorization comes from.
    private enum TransferAuthorization {
        /// The saved mode authorizes the transfer, and the per-read confirmation
        /// does not apply. The automatic schedule uses this.
        case savedMode

        /// Only the per-read intent and confirmation apply. A caller that drives
        /// one read directly uses this, which is what keeps a headless run's
        /// deleting transfer behind its own explicit confirmation.
        case perReadChoice
    }

    /// Where the read the shell shows got its transfer authorization.
    ///
    /// It is set when a read starts and kept while that read's outcome is shown, so
    /// a retry of an automatic read is authorized the same way the read was. An
    /// automatic read never reaches the separate deletion command, so the retry of
    /// one must not reach it either.
    private var attemptAuthorization: TransferAuthorization = .perReadChoice

    private func start(
        selection: CoreBluetoothPenTransport.Selection,
        authorization: TransferAuthorization
    ) {
        guard !isBusy else { return }

        attemptAuthorization = authorization

        // The read captures the intent and the confirmation it runs with, so a
        // setting changed while it runs cannot change what it does. The shell goes
        // back to the policy's default afterwards: a choice was for one read, so a
        // later one never inherits it.
        switch authorization {
        case .savedMode:
            attemptCleanupMode = syncMode.cleanupMode ?? cleanupPolicy.mode
            // The saved Delete mode is the user's standing authorization, so an
            // eligible automatic read does not ask again. Every other gate is
            // checked separately, in ``deletingReadIntent()``.
            attemptCleanupConfirmed = syncMode == .delete
        case .perReadChoice:
            attemptCleanupMode = nextReadCleanupMode
            attemptCleanupConfirmed = nextReadCleanupConfirmed
        }
        nextReadCleanupMode = cleanupPolicy.mode
        nextReadCleanupConfirmed = false

        generation += 1
        let generation = self.generation
        setPhase(.scanning)

        // A deleting read is requested only for a cleanup intent that this sync
        // confirmed, with a requested export, version-matched evidence, and durable
        // packet storage. Any other combination is an ordinary non-destructive read.
        let deletingRead = deletingReadIntent()

        let runner = runners.makeRunner(selection: selection)
        attempt = Task { [weak self] in
            guard let controller = self else { return }

            // The stages arrive from the runner's own context, so each report
            // hops back to the main actor. Reports are ordered because the
            // session reports its states in order.
            let report: @Sendable (PenSyncStage) -> Void = { [weak self] stage in
                Task { @MainActor in
                    self?.apply(stage, for: generation)
                }
            }

            do {
                let read = try await runner.run(deletingRead: deletingRead, report: report)
                try await controller.save(read, for: generation)
            } catch {
                controller.failRead(with: error, for: generation)
            }
        }
    }

    /// The deleting read this sync should request, or `nil` for an ordinary read.
    private func deletingReadIntent() -> PenDeletingReadIntent? {
        guard attemptCleanupMode == .deleteAfterAcknowledge else { return nil }
        guard attemptCleanupConfirmed else { return nil }
        guard destination.exportDirectory() != nil else { return nil }
        guard deletingReadStorage.isAvailable else { return nil }
        return PenDeletingReadIntent(
            policy: cleanupPolicy,
            requestedExport: true,
            confirmedForThisSync: true,
            durablePacketStorageAvailable: true
        )
    }

    /// Commits the read, publishes its files, and requests cleanup.
    ///
    /// A deleting read already committed its packets through the storage barrier,
    /// so it is published from the durable batch rather than imported a second
    /// time, and it never requests a separate deletion command.
    private func save(_ read: PenReadResult, for generation: Int) async throws {
        guard self.generation == generation else { return }

        let directory = destination.exportDirectory()

        if let deleting = read.deletingTransfer {
            try await saveDeletingRead(read, deleting: deleting, directory: directory, for: generation)
            return
        }

        let request = directory.map {
            PenExportRequest(pages: read.transfer.pages, destinationDirectory: $0)
        }

        let reporting: @Sendable (PenImportStage) -> Void = { [weak self] stage in
            Task { @MainActor in
                self?.apply(stage, for: generation)
            }
        }

        let outcome = try await library.importRead(
            read.transfer,
            export: request,
            reporting: reporting
        )

        guard self.generation == generation else { return }

        // Cleanup is requested after the import, never before it: the importer
        // refuses a batch that is not stored and published, so the ordering rule
        // holds even if this call is reached too early.
        //
        // A read whose deleting route closed after the handshake — a pen the
        // transfer evidence does not cover — reports that blocker. Asking the
        // importer would name the separate command gate instead, which is not what
        // kept this read non-destructive.
        let cleanup: PenCleanupOutcome
        if let refusal = read.deletingReadRefusal, attemptCleanupMode == .deleteAfterAcknowledge {
            cleanup = .skipped(reason: refusal)
        } else if attemptCleanupMode == .deleteAfterAcknowledge,
            attemptAuthorization == .savedMode
        {
            cleanup = .skipped(reason: automaticCleanupRefusal)
        } else {
            cleanup = await requestCleanup(for: outcome.save?.batchID, mode: attemptCleanupMode)
        }

        guard self.generation == generation else { return }
        settle()

        let presented = PenReadOutcome(
            summary: read.summary,
            save: outcome.save,
            export: outcome.export,
            cleanup: cleanup,
            destinationDirectory: directory,
            penState: read.penState
        )
        noteCompletedRead()
        setPhase(.complete(presented))
    }

    /// Publishes a deleting read's durable batch and reports its acknowledged
    /// prefix.
    ///
    /// The batch's packets were committed before their acknowledgements, so this
    /// step only renders files from the stored rows. It never calls
    /// `requestCleanup`: the deleting transfer is the cleanup, and a separate
    /// `0x25`/`0x27` command for the same pages would take data the transfer never
    /// covered.
    private func saveDeletingRead(
        _ read: PenReadResult,
        deleting: PenDeletingTransferReport,
        directory: String?,
        for generation: Int
    ) async throws {
        var export: PenExportReport?
        if let directory, !deleting.pages.isEmpty {
            apply(.exporting, for: generation)
            export = try await library.publish(
                deleting.batchID,
                request: PenExportRequest(
                    pages: deleting.pages,
                    destinationDirectory: directory
                )
            )
        }

        guard self.generation == generation else { return }
        settle()

        let save = PenLibrarySave(
            batchID: deleting.batchID,
            pages: deleting.pages,
            insertion: PenStrokeInsertion(
                addedStrokeCount: deleting.addedStrokeCount,
                duplicateStrokeCount: deleting.duplicateStrokeCount
            ),
            strokeCount: deleting.committedStrokeCount,
            dotCount: deleting.committedDotCount
        )

        let presented = PenReadOutcome(
            summary: read.summary,
            save: save,
            export: export,
            cleanup: .acknowledgedPrefix(
                packetCount: deleting.committedPacketCount,
                isComplete: deleting.isComplete,
                removalUncertain: deleting.acknowledgementUncertain,
                reachedEndPacket: deleting.reachedEndPacket
            ),
            destinationDirectory: directory,
            penState: read.penState,
            deletingTransfer: deleting
        )
        noteCompletedRead()
        setPhase(.complete(presented))
    }

    /// Requests cleanup for a stored batch, or explains why there is none.
    ///
    /// The mode is the intent of the step that asks: the running attempt's for a
    /// read, and the shell's current choice for a retry. It is never read from the
    /// policy here, so the intent the shell shows is the intent that is used.
    ///
    /// A cleanup problem never discards a completed save: the pen's copy is
    /// reported as skipped instead, and the library copy is unaffected.
    private func requestCleanup(for batchID: UUID?, mode: PenCleanupMode) async -> PenCleanupOutcome {
        guard let batchID else {
            return .skipped(reason: "the read stored no strokes, so there is nothing to reclaim")
        }

        // No sender is supplied: the deletion command has no evidence-backed
        // payload framing yet, so the app opens no link for it and the importer
        // reports cleanup as skipped rather than sending a guessed frame. The
        // evidence gate refuses the command before the sender is ever consulted.
        let request = PenCleanupRequest(mode: mode, sender: nil)
        do {
            return try await library.requestCleanup(batchID, request: request)
        } catch {
            return .skipped(reason: penSyncErrorMessage(for: error))
        }
    }

    /// Why an automatic sync that asked for a deleting transfer removed nothing.
    ///
    /// Automatic Sync and Delete removes packets only through the deleting
    /// transfer itself. It never falls back to the separate `0x25`/`0x27` command,
    /// so the reason it reports is the transfer gate that closed rather than the
    /// command gate, which no automatic read ever consults.
    private var automaticCleanupRefusal: String {
        cleanupUnavailableReason
            ?? "the deleting transfer did not run, and an automatic sync removes packets"
                + " only through that transfer"
    }

    /// Ends the attempt, leaving the read's own intent in place.
    ///
    /// The read's intent stays available so the shell keeps showing what it used and
    /// so a retry of that read can still be given a different choice; the next read's
    /// intent is independent of it.
    private func settle() {
        attempt = nil
    }

    /// Publishes a phase and releases anyone waiting for the controller to become
    /// available.
    ///
    /// The automatic schedule waits on ``waitUntilAvailable()`` after it asks for a
    /// read. Releasing the waiters here, rather than at each call site, is what keeps
    /// a new lap from starting while a read is still in flight or while the user is
    /// answering a question about which pen to use.
    private func setPhase(_ next: Phase) {
        phase = next
        guard !isBusy, !isAwaitingChoice else { return }
        let waiters = availabilityWaiters
        availabilityWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Attempt updates

    private func apply(_ stage: PenSyncStage, for generation: Int) {
        guard self.generation == generation else { return }
        setPhase(Phase(stage))
    }

    private func apply(_ stage: PenImportStage, for generation: Int) {
        guard self.generation == generation else { return }
        switch stage {
        case .saving: setPhase(.saving)
        case .exporting: setPhase(.exporting)
        }
    }

    private func finishRetry(
        with report: PenExportReport,
        cleanup: PenCleanupOutcome,
        for generation: Int,
        base outcome: PenReadOutcome
    ) {
        guard self.generation == generation else { return }
        settle()

        let updated = PenReadOutcome(
            summary: outcome.summary,
            save: outcome.save,
            export: report,
            cleanup: cleanup,
            destinationDirectory: outcome.destinationDirectory,
            penState: outcome.penState,
            deletingTransfer: outcome.deletingTransfer
        )
        setPhase(.complete(updated))
    }

    /// Records that a read completed, which is what the menu's status line dates.
    ///
    /// A read that carried no strokes still completes: the pen was reached and read,
    /// so reporting that the pen has not synced would be false. Only a read calls
    /// this. An export retry republishes a read that already completed, so it leaves
    /// the date alone.
    private func noteCompletedRead() {
        lastAttemptResult = .completedRead(at: Date())
    }

    /// Classifies a failed read for the menu's status line.
    ///
    /// A missing pen is its own status rather than a generic failure, because it is
    /// the condition the interval exists to report on. Two shapes return `nil` so the
    /// caller records nothing and the previous status stays on show. A cancellation
    /// is the user withdrawing the read, so nothing failed to be found; every shape
    /// the error presentation treats as a cancellation is listed, because the
    /// session, the transport, and Swift's own task cancellation all produce one. A
    /// several-pens answer is a question rather than a failure, and the app is
    /// waiting for the user to answer it.
    private static func result(for error: any Error) -> AttemptResult? {
        switch error {
        case let bluetoothError as PenBluetoothError:
            switch bluetoothError {
            case .noMatchingPenFound: return .notDetected
            case .multiplePensFound: return nil
            case .cancelled: return nil
            default: return .failed
            }
        case let sessionError as PenSessionError:
            return sessionError == .cancelled ? nil : .failed
        case is CancellationError:
            return nil
        default:
            return .failed
        }
    }

    /// Records a failed read and publishes its failure.
    ///
    /// Only a read goes through here. The export retry calls ``fail(with:for:)``
    /// directly, because a failed republish does not change when the pen last synced.
    private func failRead(with error: any Error, for generation: Int) {
        guard self.generation == generation else { return }
        if let result = Self.result(for: error) {
            lastAttemptResult = result
        }
        fail(with: error, for: generation)
    }

    private func fail(with error: any Error, for generation: Int) {
        guard self.generation == generation else { return }

        // Several matching pens is a question, not a failure: no pen is picked
        // silently, so the user answers it. No read has run yet, so the start that
        // asked the question consumed nothing: the intent it captured — and the
        // confirmation the user gave for it — are handed back to the shell, and the
        // pen the user chooses uses them. Restoring only the intent would silently
        // discard the confirmation, and the confirmed read would keep the pen's copy.
        if let bluetoothError = error as? PenBluetoothError,
            case .multiplePensFound(_, let candidates) = bluetoothError
        {
            attempt = nil
            nextReadCleanupMode = attemptCleanupMode
            nextReadCleanupConfirmed = attemptCleanupConfirmed
            setPhase(.choosingPen(candidates: candidates))
            return
        }

        settle()

        setPhase(
            .failed(
                message: penSyncErrorMessage(for: error),
                diagnostic: penSyncErrorDiagnostic(for: error)
            )
        )
    }
}

extension PenSyncController.Phase {
    /// Maps a stage to the phase that presents it.
    public init(_ stage: PenSyncStage) {
        switch stage {
        case .scanning: self = .scanning
        case .connecting: self = .connecting
        case .verifying: self = .verifying
        case .syncing: self = .syncing
        }
    }
}
