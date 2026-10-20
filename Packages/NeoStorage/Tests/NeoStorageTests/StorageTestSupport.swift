import Foundation
import NeoCore
import XCTest

@testable import NeoStorage

/// Creates and removes a temporary directory for one test.
struct TemporaryDirectory {
    /// The directory the test may write to.
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neostorage-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A file URL inside the directory.
    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Removes the directory and its contents.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A failure a test injects into the store.
enum InjectedFailure: Error, Hashable {
    case stopped
}

/// A publisher whose per-format outcomes a test scripts.
struct StubExportPublisher: PenExportPublisher {
    /// The formats that fail, and why.
    var failures: [PenExportFormat: String] = [:]

    /// Every publication the publisher was asked for.
    let calls: PublicationCalls

    init(failures: [PenExportFormat: String] = [:], calls: PublicationCalls = PublicationCalls()) {
        self.failures = failures
        self.calls = calls
    }

    func publish(_ request: PenExportRequest, content: [PenPageContent]) async -> PenExportReport {
        await calls.record(request: request, content: content)
        return PenExportReport(
            artifacts: request.formats.map { format in
                PenExportArtifact(
                    format: format,
                    path: "\(request.destinationDirectory)/page.\(format.rawValue)",
                    byteCount: content.reduce(0) { $0 + $1.dotCount },
                    status: failures[format].map { .failed(reason: $0) } ?? .published
                )
            }
        )
    }
}

/// A deletion channel whose answer a test scripts, recording every scope it was
/// asked to delete.
///
/// The default confirms the scope it was handed, mimicking a pen that proves
/// removal of exactly the recorded data.
struct StubDeletionSender: PenDeletionSender {
    /// The outcome one call returns. It is async so a test can inspect durable
    /// state at the moment of the send.
    var outcome: @Sendable (PenDeletionScope) async -> PenDeletionOutcome

    /// Every deletion the sender was asked for.
    let calls: DeletionCalls

    init(
        outcome: @escaping @Sendable (PenDeletionScope) async -> PenDeletionOutcome = { .confirmed($0) },
        calls: DeletionCalls = DeletionCalls()
    ) {
        self.outcome = outcome
        self.calls = calls
    }

    func delete(_ scope: PenDeletionScope) async throws -> PenDeletionOutcome {
        await calls.record(scope)
        return await outcome(scope)
    }
}

/// A deletion channel whose send always fails.
///
/// It models a link that breaks after the request was journaled, so the effect of
/// the deletion is unknown.
struct FailingDeletionSender: PenDeletionSender {
    /// The failure one call throws.
    var failure: any Error = InjectedFailure.stopped

    /// Every deletion the sender was asked for.
    let calls: DeletionCalls

    init(failure: any Error = InjectedFailure.stopped, calls: DeletionCalls = DeletionCalls()) {
        self.failure = failure
        self.calls = calls
    }

    func delete(_ scope: PenDeletionScope) async throws -> PenDeletionOutcome {
        await calls.record(scope)
        throw failure
    }
}

/// A suspension point a test can hold a caller inside.
///
/// Every `await` in the importer is a point where another call can run, so a test
/// that needs to observe one has to hold a call there. This gate records that a
/// caller entered it, so a test can act at that moment instead of guessing at a
/// scheduling order.
actor InputGate {
    private var isOpen = false
    private var hasEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Records the call and suspends until ``open()``.
    func wait() async {
        hasEntered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Suspends until a caller has reached the gate.
    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    /// Releases every waiter, and lets later callers through at once.
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A cleanup journal that holds its first write open until a test opens the gate.
///
/// It models the suspension inside `requestCleanup` between its checks and its
/// journal write, which is the window a second request or a cancellation can land
/// in.
actor GatedCleanupJournal: PenCleanupJournal {
    private let inner: any PenCleanupJournal
    private let gate: InputGate
    private var hasGatedWrite = false

    init(inner: any PenCleanupJournal, gate: InputGate) {
        self.inner = inner
        self.gate = gate
    }

    func record(_ state: PenCleanupState, scope: PenDeletionScope) async throws {
        if !hasGatedWrite {
            hasGatedWrite = true
            await gate.wait()
        }
        try await inner.record(state, scope: scope)
    }

    func latestState(batchID: UUID) async throws -> PenCleanupState? {
        try await inner.latestState(batchID: batchID)
    }

    func recordedScope(batchID: UUID) async throws -> PenDeletionScope? {
        try await inner.recordedScope(batchID: batchID)
    }

    func outstandingScopes() async throws -> [PenDeletionScope] {
        try await inner.outstandingScopes()
    }
}

/// A cleanup journal that fails one state's write.
///
/// It models a journal write that fails after the pen has already answered, which
/// a caller must still report as what the pen did.
actor FailingCleanupJournal: PenCleanupJournal {
    private let inner: any PenCleanupJournal
    private let failing: PenCleanupState

    init(inner: any PenCleanupJournal, failing: PenCleanupState) {
        self.inner = inner
        self.failing = failing
    }

    func record(_ state: PenCleanupState, scope: PenDeletionScope) async throws {
        if state == failing { throw InjectedFailure.stopped }
        try await inner.record(state, scope: scope)
    }

    func latestState(batchID: UUID) async throws -> PenCleanupState? {
        try await inner.latestState(batchID: batchID)
    }

    func recordedScope(batchID: UUID) async throws -> PenDeletionScope? {
        try await inner.recordedScope(batchID: batchID)
    }

    func outstandingScopes() async throws -> [PenDeletionScope] {
        try await inner.outstandingScopes()
    }
}

/// Records the deletion scopes a stub sender was asked for.
actor DeletionCalls {
    private var scopes: [PenDeletionScope] = []

    /// Records one deletion request.
    func record(_ scope: PenDeletionScope) {
        scopes.append(scope)
    }

    /// Every deletion scope, in order.
    var allScopes: [PenDeletionScope] { scopes }
}

/// Records the cleanup state a test observed when a deletion was sent.
actor CleanupStateProbe {
    private var observed: PenCleanupState?

    /// Stores the state seen at the send.
    func record(_ state: PenCleanupState?) {
        observed = state
    }

    /// The state seen at the send, or `nil` when none was recorded.
    var state: PenCleanupState? { observed }
}

/// Records the publications a stub publisher was asked for.
actor PublicationCalls {
    private var requests: [PenExportRequest] = []
    private var contents: [[PenPageContent]] = []

    /// Records one publication.
    func record(request: PenExportRequest, content: [PenPageContent]) {
        requests.append(request)
        contents.append(content)
    }

    /// Every publication request, in order.
    var allRequests: [PenExportRequest] { requests }

    /// Every publication's page content, in order.
    var allContent: [[PenPageContent]] { contents }
}
