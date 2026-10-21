import Foundation

/// How one sync treats the pen's copy of the data it read.
///
/// The mode is the *intent* for a sync, not permission to delete. Whether a
/// deletion command may actually be sent is decided separately by
/// ``PenDeletionEvidence``, so an intent of ``deleteAfterAcknowledge`` still
/// leaves the pen's copy untouched while the evidence gate is closed.
public enum PenCleanupMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Leave the strokes on the pen.
    ///
    /// Retention is an explicit choice, and it applies to one sync only: a later
    /// sync starts from the default again.
    case keepOnPen

    /// Remove the verified data from the pen after the batch is stored and its
    /// export is published.
    ///
    /// This is the default intent. The ordering rule is what makes it safe: the
    /// deletion is requested only after a complete transfer, a durable import, and
    /// an export published in full. A read that requested no export keeps its pen
    /// copy, because there is then nothing published to fall back on.
    case deleteAfterAcknowledge
}

/// The durable states of a pen cleanup request.
///
/// The three states are the journal a crash mid-delete needs. `prepared` records
/// the exact scope before anything can be sent, `requested` is written before the
/// bytes can reach the pen, and `confirmed` is written only when an
/// evidence-backed response proves the recorded scope was removed.
public enum PenCleanupState: String, Hashable, Sendable, Codable, CaseIterable {
    /// A cleanup request is recorded with its scope but has not been sent.
    case prepared

    /// A cleanup request has been sent to the pen.
    case requested

    /// The pen confirmed removal of the recorded scope.
    case confirmed
}

/// Which pen deletion command a request targets.
///
/// The A1 has two identifiers, `0x25` and `0x27`. The physical trace of 2026-10-20
/// proves `0x25` note-scoped and finds `0x27` refused, so the evidence record names
/// the command it proves rather than assuming that both work.
public enum PenDeletionTarget: String, Hashable, Sendable, Codable, CaseIterable {
    /// The note-scoped deletion request, `0x25`.
    case note

    /// The page-scoped deletion request, `0x27`.
    case page
}

/// One safety condition the deletion evidence gate requires.
///
/// Every condition needs a physical A1 trace that establishes it. A trace's mere
/// existence does not open the gate, and a trace showing unsafe behavior closes
/// it.
public enum PenDeletionCondition: String, Hashable, Sendable, Codable, CaseIterable {
    /// The request payload layout, and the response framing that answers it.
    case payloadFraming

    /// That the command removes exactly the verified data, including when newer
    /// strokes exist on the same page or note.
    case deletionScope

    /// What the `0xA5` or `0xA7` response means: acceptance of the command, or
    /// completed removal of the requested scope.
    case responseMeaning

    /// That an interrupted transfer leaves every not-yet-imported stroke
    /// retrievable.
    case interruptedTransferRetention

    /// A short phrase naming the condition, for a message.
    public var summary: String {
        switch self {
        case .payloadFraming:
            return "the request and response payload framing"
        case .deletionScope:
            return "the deletion scope"
        case .responseMeaning:
            return "the response meaning"
        case .interruptedTransferRetention:
            return "interrupted-transfer retention"
        }
    }
}

/// The evidence gate behind the pen deletion commands.
///
/// The gate is data, not a constant: ``PenCleanupPolicy/deletionEnabled`` derives
/// from this record, so opening the gate is a change to the recorded verdicts
/// rather than an edit to a boolean. A condition that is absent is `pending`, and
/// a condition a trace shows to be unsafe is `unsafe`; neither authorizes a
/// deletion.
public struct PenDeletionEvidence: Hashable, Sendable {
    /// What one trace established about a condition.
    public enum Verdict: String, Hashable, Sendable, Codable, CaseIterable {
        /// No trace has settled the condition.
        case pending

        /// A trace establishes the condition is safe.
        case safe

        /// A trace establishes the condition is not safe.
        case unsafe

        /// Whether the verdict permits a deletion.
        public var permitsDeletion: Bool { self == .safe }
    }

    /// The deletion command a trace proved for the verified data, or `nil` while
    /// no trace has settled which command scopes to what.
    public let target: PenDeletionTarget?

    private let verdicts: [PenDeletionCondition: Verdict]

    /// Creates an evidence record.
    ///
    /// - Parameters:
    ///   - target: The command a trace proved, or `nil` while it is unsettled.
    ///   - verdicts: One verdict per condition. A condition left out is `pending`.
    public init(
        target: PenDeletionTarget? = nil,
        verdicts: [PenDeletionCondition: Verdict] = [:]
    ) {
        self.target = target
        self.verdicts = verdicts
    }

    /// The record a build with no physical deletion trace holds.
    ///
    /// Every condition is `pending` and no command is proven, so the gate is
    /// closed and no deletion may be sent.
    public static let unestablished = PenDeletionEvidence()

    /// The record the physical A1 trace of 2026-10-20 establishes.
    ///
    /// The deletion experiment recorded in the "Deletion experiment, 2026-10-20"
    /// section of `docs/protocol-a1.md` traced both commands against the pen and
    /// settled every condition:
    ///
    /// - both request layouts were accepted and both answers carry an error code and
    ///   a little-endian length, so `payloadFraming` is `safe`;
    /// - the first payload byte of an `0xA5` answer counts the notes whose data went
    ///   — `00` for a note the pen does not hold and `01` for one it does — and the
    ///   read that followed found the data gone, so `responseMeaning` is `safe`;
    /// - the pen refuses `0x27` with `0x05` (`NotSupportCMD`), so the only deletion it
    ///   accepts takes a whole note. The `0x25` request that removed data also removed
    ///   page 1, where a mark no read had imported had been written, so
    ///   `deletionScope` is `unsafe`, and that verdict is what keeps the gate shut;
    /// - the 2026-10-19 transfer-option experiment (`opt02-abort`,
    ///   `opt02-abort-recovery`) showed that an interrupted read leaves every stroke
    ///   retrievable, so `interruptedTransferRetention` is `safe`.
    ///
    /// The verdicts are recorded rather than left `pending` so a build's report names
    /// the real reason the gate is closed — the deletion scope — instead of claiming
    /// that no trace exists.
    public static let physicalTrace2026_10_20 = PenDeletionEvidence(
        target: .note,
        verdicts: [
            .payloadFraming: .safe,
            .deletionScope: .unsafe,
            .responseMeaning: .safe,
            .interruptedTransferRetention: .safe
        ]
    )

    /// The verdict recorded for a condition.
    public func verdict(for condition: PenDeletionCondition) -> Verdict {
        verdicts[condition] ?? .pending
    }

    /// Whether every condition is `safe` and a command is proven.
    public var isSafe: Bool {
        guard target != nil else { return false }
        return PenDeletionCondition.allCases.allSatisfy { verdict(for: $0).permitsDeletion }
    }

    /// The conditions that are not `safe`, in the canonical order.
    public var blockingConditions: [PenDeletionCondition] {
        PenDeletionCondition.allCases.filter { !verdict(for: $0).permitsDeletion }
    }

    /// Whether the record proves one command safe to send.
    ///
    /// A record proves a command only when the trace settled which command the
    /// verified data scopes to and every condition is `safe`.
    public func proves(_ target: PenDeletionTarget) -> Bool {
        self.target == target && isSafe
    }

    /// Why the gate is closed, for a user-visible message.
    ///
    /// Use this when no particular command is in play. When one is, use
    /// ``blockingReason(for:)`` so the message also names a scope mismatch.
    public var blockingReason: String {
        blockingReason(intendedScope: nil)
    }

    /// Why the gate refuses a deletion command scoped to `target`.
    ///
    /// - Parameter target: The scope the command would delete.
    /// - Returns: A message naming the scope mismatch when the trace proves a
    ///   different command, plus every condition that is not `safe`.
    public func blockingReason(for target: PenDeletionTarget) -> String {
        blockingReason(intendedScope: target)
    }

    private func blockingReason(intendedScope: PenDeletionTarget?) -> String {
        var reasons: [String] = []
        switch (target, intendedScope) {
        case (nil, _):
            reasons.append(
                "no trace has established which deletion command scopes to the verified data"
            )
        case (let proven?, let intended?) where proven != intended:
            reasons.append(
                "the recorded trace proves \(proven.rawValue)-scoped deletion, not \(intended.rawValue)-scoped"
            )
        default:
            break
        }
        for condition in blockingConditions {
            reasons.append("\(condition.summary) is \(verdict(for: condition).rawValue)")
        }
        return "the deletion evidence gate is closed: " + reasons.joined(separator: "; ")
    }
}

/// The pen cleanup policy a library is built with.
public struct PenCleanupPolicy: Hashable, Sendable {
    /// The intent the policy applies when a sync makes no choice of its own.
    ///
    /// The default is ``PenCleanupMode/deleteAfterAcknowledge``: cleanup is the
    /// normal outcome of a sync. It is an intent only — deletion stays
    /// unreachable until ``evidence`` proves it safe.
    public let mode: PenCleanupMode

    /// The evidence behind the deletion commands.
    public let evidence: PenDeletionEvidence

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - mode: The default intent for a sync.
    ///   - evidence: The recorded deletion evidence. It defaults to the physical A1
    ///     trace, which keeps the gate closed.
    public init(
        mode: PenCleanupMode = .deleteAfterAcknowledge,
        evidence: PenDeletionEvidence = .physicalTrace2026_10_20
    ) {
        self.mode = mode
        self.evidence = evidence
    }

    /// Whether the app may send a deletion request to the pen.
    ///
    /// Derived from ``evidence``, never from a constant. The physical A1 trace
    /// records the deletion scope as `unsafe`, so this is `false` and the pen's copy
    /// is retained.
    public var deletionEnabled: Bool {
        evidence.isSafe
    }

    /// The deletion command the evidence proves, or `nil` while the gate is
    /// closed.
    public var provenTarget: PenDeletionTarget? {
        evidence.isSafe ? evidence.target : nil
    }

    /// Why cleanup cannot run for a sync that intends it, or `nil` when it can.
    ///
    /// A sync that chose retention has nothing to explain: retaining is the
    /// outcome, not a skipped cleanup.
    public func skipReason(for mode: PenCleanupMode) -> String? {
        guard mode == .deleteAfterAcknowledge else { return nil }
        guard deletionEnabled else { return evidence.blockingReason }
        return nil
    }
}

/// The exact scope one deletion request targets.
///
/// The scope is what makes a crash mid-delete recoverable: it is recorded
/// durably before anything is sent, so a later read can be compared with it
/// instead of a deletion being repeated blindly.
public struct PenDeletionScope: Hashable, Sendable, Codable {
    /// The batch whose verified data the request targets.
    public let batchID: UUID

    /// The deletion command the evidence proved for this scope.
    public let target: PenDeletionTarget

    /// The pages the request targets, in canonical order.
    public let pages: [PageIdentity]

    /// Creates a scope.
    ///
    /// - Parameters:
    ///   - batchID: The batch whose verified data is being reclaimed.
    ///   - target: The command the evidence proved.
    ///   - pages: The pages to target. They are stored in canonical order, so a
    ///     recorded scope never depends on transfer order.
    public init(batchID: UUID, target: PenDeletionTarget, pages: [PageIdentity]) {
        self.batchID = batchID
        self.target = target
        self.pages = pages.sorted(by: PageIdentity.canonicalOrder)
    }

    /// How many pages the request targets.
    public var pageCount: Int { pages.count }
}

/// What the pen answered to a deletion request.
public enum PenDeletionOutcome: Hashable, Sendable {
    /// An evidence-backed response proved the recorded scope was removed.
    case confirmed(PenDeletionScope)

    /// No acknowledgement arrived before the request's deadline, so the effect is
    /// unknown.
    case unacknowledged(PenDeletionScope)

    /// The pen answered with a non-zero error code, so the command was rejected.
    case refused(scope: PenDeletionScope, code: UInt8)

    /// The scope the outcome is about.
    public var scope: PenDeletionScope {
        switch self {
        case .confirmed(let scope), .unacknowledged(let scope), .refused(let scope, _):
            return scope
        }
    }

    /// Whether the pen proved the recorded scope was removed.
    public var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }
}

/// A channel that sends one pen deletion command.
///
/// The protocol keeps the storage layer free of transport types: a durable
/// importer needs only a way to hand a proven scope to the pen, and a test can
/// supply a recording implementation instead of a radio.
public protocol PenDeletionSender: Sendable {
    /// Sends one deletion command for a scope that has already been imported and
    /// published.
    ///
    /// - Parameter scope: The exact scope to remove.
    /// - Returns: What the pen answered. A non-confirming outcome leaves the
    ///   request outstanding.
    func delete(_ scope: PenDeletionScope) async throws -> PenDeletionOutcome
}

/// What one sync's cleanup ended with, in the shape a caller presents.
public enum PenCleanupOutcome: Hashable, Sendable {
    /// Retention was chosen for this sync, so no deletion was requested.
    case retainedByChoice

    /// The pen confirmed removal of the recorded scope.
    case reclaimed(pageCount: Int)

    /// Cleanup was intended but did not run, and this says why. The pen's copy is
    /// untouched.
    case skipped(reason: String)

    /// A deletion request was sent but its effect is not proven, so it stays
    /// outstanding and is never repeated automatically.
    case outstanding(reason: String)

    /// Whether the pen's copy was reclaimed.
    public var isReclaimed: Bool {
        if case .reclaimed = self { return true }
        return false
    }

    /// A one-line statement of the outcome, for the menu and the window.
    public var summary: String {
        switch self {
        case .retainedByChoice:
            return "The pen's strokes were kept on the pen because retention was chosen for this read."
        case .reclaimed(let pageCount):
            return "Reclaimed \(pageCount) page\(pageCount == 1 ? "" : "s") from the pen."
                + " The library copy remains available."
        case .skipped(let reason):
            return "The pen kept its strokes: \(reason)"
        case .outstanding(let reason):
            return "A deletion request is outstanding: \(reason)"
                + " The library copy is unaffected and the request is not repeated automatically."
        }
    }
}

/// How one sync asks the library to treat the pen's copy.
public struct PenCleanupRequest: Sendable {
    /// The intent for this sync.
    ///
    /// A choice applies to one sync only: a later sync supplies its own request
    /// rather than inheriting this one.
    public let mode: PenCleanupMode

    /// The channel that sends the deletion command, or `nil` when no pen link is
    /// available.
    public let sender: (any PenDeletionSender)?

    /// Creates a cleanup request.
    ///
    /// - Parameters:
    ///   - mode: The intent for this sync.
    ///   - sender: The channel to send a proven deletion over, or `nil` when the
    ///     caller has no link. A `nil` sender never sends anything; cleanup is
    ///     reported as skipped.
    public init(mode: PenCleanupMode = .deleteAfterAcknowledge, sender: (any PenDeletionSender)? = nil) {
        self.mode = mode
        self.sender = sender
    }

    /// A request that retains the pen's copy for this sync.
    public static let retained = PenCleanupRequest(mode: .keepOnPen)
}

/// A durable journal for pen cleanup requests.
///
/// The journal holds the scope of each request as well as its state, so a process
/// that restarts mid-delete can compare the recorded scope with a fresh read
/// instead of repeating the request.
public protocol PenCleanupJournal: Sendable {
    /// Records a cleanup state for a scope, replacing no earlier state.
    func record(_ state: PenCleanupState, scope: PenDeletionScope) async throws

    /// Returns the most recently recorded state for a batch.
    ///
    /// - Throws: When a recorded row cannot be decoded. A row this build cannot
    ///   read is refused rather than reported as no state, so a caller never
    ///   mistakes it for a request that was never made.
    func latestState(batchID: UUID) async throws -> PenCleanupState?

    /// Returns the scope recorded for a batch, or `nil` when none was recorded.
    ///
    /// - Throws: When a recorded row cannot be decoded, for the same reason as
    ///   ``latestState(batchID:)``.
    func recordedScope(batchID: UUID) async throws -> PenDeletionScope?

    /// Returns every scope whose latest state is `requested`, oldest first.
    func outstandingScopes() async throws -> [PenDeletionScope]
}
