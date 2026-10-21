import XCTest

@testable import NeoCore

/// Tests for the deleting-transfer route: its evidence record, its authorization
/// gate, and the durable shape a deleting batch reports.
///
/// The route is separate from the `0x25`/`0x27` command route on purpose, so the
/// tests check the two gates independently rather than treating one as evidence
/// for the other.
final class PenDeletingTransferTests: XCTestCase {
    private let tracedPen = PenDeletingTransferIdentity.physicalA1_2026_10_21

    /// Every condition with the traced identity, so a test can vary one verdict.
    private func verdicts(
        overriding condition: PenDeletionCondition? = nil,
        to verdict: PenDeletionEvidence.Verdict = .safe
    ) -> [PenDeletionCondition: PenDeletionEvidence.Verdict] {
        var verdicts = Dictionary(
            uniqueKeysWithValues: PenDeletionCondition.allCases.map {
                ($0, PenDeletionEvidence.Verdict.safe)
            }
        )
        if let condition {
            verdicts[condition] = verdict
        }
        return verdicts
    }

    // MARK: - Transfer evidence

    func testTransferEvidenceIsSafeOnlyForTheTracedIdentity() {
        let evidence = PenDeletingTransferEvidence.physicalTrace2026_10_21

        XCTAssertEqual(evidence.identity, tracedPen)
        XCTAssertEqual(tracedPen.deviceName, "NWP-F151")
        XCTAssertEqual(tracedPen.firmwareVersion, "3.00")
        XCTAssertEqual(tracedPen.protocolVersion, "2.23")
        XCTAssertFalse(tracedPen.isCompressed, "the traced transfer was uncompressed")
        XCTAssertTrue(evidence.isSafe)
        XCTAssertEqual(evidence.blockingConditions, [])
        XCTAssertTrue(evidence.authorizes(tracedPen))
        XCTAssertNil(evidence.refusal(for: tracedPen))
    }

    func testTransferEvidenceRefusesAnyChangedIdentityOrResponseShape() {
        let evidence = PenDeletingTransferEvidence.physicalTrace2026_10_21

        let candidates: [PenDeletingTransferIdentity] = [
            PenDeletingTransferIdentity(
                deviceName: "NWP-F151",
                firmwareVersion: "3.01",
                protocolVersion: "2.23",
                isCompressed: false
            ),
            PenDeletingTransferIdentity(
                deviceName: "NWP-F151",
                firmwareVersion: "3.00",
                protocolVersion: "2.24",
                isCompressed: false
            ),
            PenDeletingTransferIdentity(
                deviceName: "NWP-A1",
                firmwareVersion: "3.00",
                protocolVersion: "2.23",
                isCompressed: false
            ),
            PenDeletingTransferIdentity(
                deviceName: "NWP-F151",
                firmwareVersion: "3.00",
                protocolVersion: "2.23",
                isCompressed: true
            ),
        ]

        for candidate in candidates {
            XCTAssertFalse(
                evidence.authorizes(candidate),
                "\(candidate.summary) is outside the traced identity"
            )
            let refusal = try? XCTUnwrap(evidence.refusal(for: candidate))
            XCTAssertNotNil(refusal)
            XCTAssertTrue(
                refusal?.contains("the deleting-transfer evidence gate is closed") ?? false,
                "a refusal must name the gate: \(refusal ?? "nil")"
            )
            XCTAssertTrue(
                refusal?.contains(tracedPen.summary) ?? false,
                "a refusal must name the traced identity it covers"
            )
        }
    }

    func testTransferEvidenceIsUnsafeWhileAnyVerdictIsNotSafe() {
        XCTAssertFalse(PenDeletingTransferEvidence.unestablished.isSafe)
        XCTAssertFalse(
            PenDeletingTransferEvidence.unestablished.authorizes(tracedPen),
            "a record with no identity authorizes nothing"
        )
        XCTAssertFalse(PenDeletingTransferEvidence(identity: tracedPen).isSafe)
        XCTAssertFalse(
            PenDeletingTransferEvidence(identity: tracedPen).authorizes(tracedPen),
            "an identity with no verdicts is not safe"
        )

        // Each condition on its own is enough to close the route, whether it is
        // pending or contrary.
        for condition in PenDeletionCondition.allCases {
            let pending = PenDeletingTransferEvidence(
                identity: tracedPen,
                verdicts: verdicts(overriding: condition, to: .pending)
            )
            XCTAssertFalse(pending.isSafe, "\(condition) pending must not open the route")
            XCTAssertFalse(pending.authorizes(tracedPen))
            XCTAssertEqual(pending.blockingConditions, [condition])

            let unsafe = PenDeletingTransferEvidence(
                identity: tracedPen,
                verdicts: verdicts(overriding: condition, to: .unsafe)
            )
            XCTAssertFalse(unsafe.isSafe, "\(condition) unsafe must not open the route")
            XCTAssertEqual(unsafe.blockingConditions, [condition])
            XCTAssertTrue(
                unsafe.refusal(for: tracedPen)?.contains(condition.summary) ?? false,
                "the refusal names the blocking condition"
            )
        }
    }

    func testTransferRouteAndCommandRouteAreIndependent() {
        // The shipped policy: the command scope is unsafe, the transfer record is
        // safe. One route's verdicts never speak for the other.
        let shipped = PenCleanupPolicy()
        XCTAssertFalse(shipped.deletionEnabled, "the 0x25 scope keeps the command gate shut")
        XCTAssertTrue(shipped.transferDeletionEnabled(for: tracedPen))
        XCTAssertNil(shipped.transferDeletionRefusal(for: tracedPen))

        // And the reverse: an open command gate does not authorize a transfer.
        let safeCommandVerdicts = Dictionary(
            uniqueKeysWithValues: PenDeletionCondition.allCases.map {
                ($0, PenDeletionEvidence.Verdict.safe)
            }
        )
        let commandOnly = PenCleanupPolicy(
            evidence: PenDeletionEvidence(target: .note, verdicts: safeCommandVerdicts),
            transferEvidence: .unestablished
        )
        XCTAssertTrue(commandOnly.deletionEnabled)
        XCTAssertFalse(commandOnly.transferDeletionEnabled(for: tracedPen))
        XCTAssertNotNil(commandOnly.transferDeletionRefusal(for: tracedPen))
    }

    // MARK: - Authorization

    func testDeletingReadAuthorizationRequiresEveryPrecondition() {
        let policy = PenCleanupPolicy()

        // The preconditions are checked in the order the shell presents them, so
        // each missing one is reported rather than folded into a single refusal.
        assertRefusal(
            policy.deletingReadAuthorization(
                pen: tracedPen,
                requestedExport: false,
                confirmedForThisSync: true,
                durablePacketStorageAvailable: true
            ),
            is: .noExportRequested
        )
        assertRefusal(
            policy.deletingReadAuthorization(
                pen: tracedPen,
                requestedExport: true,
                confirmedForThisSync: false,
                durablePacketStorageAvailable: true
            ),
            is: .notConfirmedForThisSync
        )
        assertRefusal(
            policy.deletingReadAuthorization(
                pen: tracedPen,
                requestedExport: true,
                confirmedForThisSync: true,
                durablePacketStorageAvailable: false
            ),
            is: .durableStorageUnavailable(reason: "no writable library is available")
        )
        assertRefusal(
            policy.deletingReadAuthorization(
                pen: PenDeletingTransferIdentity(
                    deviceName: "NWP-F151",
                    firmwareVersion: "3.00",
                    protocolVersion: "2.23",
                    isCompressed: true
                ),
                requestedExport: true,
                confirmedForThisSync: true,
                durablePacketStorageAvailable: true
            ),
            is: .evidenceClosed(
                reason: PenDeletingTransferEvidence.physicalTrace2026_10_21.refusal(
                    for: PenDeletingTransferIdentity(
                        deviceName: "NWP-F151",
                        firmwareVersion: "3.00",
                        protocolVersion: "2.23",
                        isCompressed: true
                    )
                ) ?? ""
            )
        )

        // All four preconditions hold: the authorization carries the identity its
        // evidence covers, so the session can re-check the connected pen.
        switch policy.deletingReadAuthorization(
            pen: tracedPen,
            requestedExport: true,
            confirmedForThisSync: true,
            durablePacketStorageAvailable: true
        ) {
        case .success(let authorization):
            XCTAssertEqual(authorization.requiredIdentity, tracedPen)
        case .failure(let refusal):
            XCTFail("expected an authorization, got \(refusal)")
        }

        // A closed transfer record refuses an otherwise perfect request.
        let closed = PenCleanupPolicy(transferEvidence: .unestablished)
        assertRefusal(
            closed.deletingReadAuthorization(
                pen: tracedPen,
                requestedExport: true,
                confirmedForThisSync: true,
                durablePacketStorageAvailable: true
            ),
            is: .evidenceClosed(
                reason: PenDeletingTransferEvidence.unestablished.refusal(for: tracedPen) ?? ""
            )
        )
    }

    func testDeletingReadIntentResolvesAgainstTheConnectedPen() {
        let intent = PenDeletingReadIntent(
            policy: PenCleanupPolicy(),
            requestedExport: true,
            confirmedForThisSync: true,
            durablePacketStorageAvailable: true
        )

        XCTAssertEqual(intent.authorization(for: tracedPen).successValue?.requiredIdentity, tracedPen)
        XCTAssertNil(
            intent.authorization(
                for: PenDeletingTransferIdentity(
                    deviceName: "NWP-F151",
                    firmwareVersion: "2.99",
                    protocolVersion: "2.23",
                    isCompressed: false
                )
            ).successValue
        )

        // An intent built without the confirmation resolves to the refusal, so a
        // caller cannot reach the deleting option by constructing an intent.
        let unconfirmed = PenDeletingReadIntent(
            policy: PenCleanupPolicy(),
            requestedExport: true,
            confirmedForThisSync: false,
            durablePacketStorageAvailable: true
        )
        XCTAssertEqual(unconfirmed.authorization(for: tracedPen).failureValue, .notConfirmedForThisSync)
    }

    // MARK: - Durable batch shape

    func testDeletingReadStorageReportsAvailability() {
        XCTAssertFalse(PenDeletingReadStorage.unavailable.isAvailable)
        XCTAssertTrue(
            PenDeletingReadStorage(barrier: NoopBarrier()).isAvailable,
            "a barrier makes the storage available"
        )
        XCTAssertNil(PenDeletingReadStorage(barrier: NoopBarrier()).unavailableReason)
    }

    func testBatchRecordSeparatesTransferCompletionFromPublication() {
        let page = PageIdentity(section: 3, owner: 27, book: 700, page: 36)
        let packet = PenImportPacketProgress(
            sectionOwnerID: 27,
            noteID: 700,
            packetID: 1,
            strokeCount: 13,
            isEndPacket: false
        )

        // An ordinary committed read: retryable, and its pages are not yet safe for
        // a separate command because it has not published.
        let ordinaryCommitted = PenImportBatchRecord(
            batchID: UUID(),
            state: .committed,
            pages: [page],
            strokeCount: 13,
            dotCount: 100
        )
        XCTAssertFalse(ordinaryCommitted.isDeletingTransfer)
        XCTAssertFalse(ordinaryCommitted.hasDurablePackets)
        XCTAssertTrue(ordinaryCommitted.isTransferComplete)
        XCTAssertTrue(ordinaryCommitted.isPublicationRetryable)
        XCTAssertTrue(ordinaryCommitted.blocksCommandDeletionScope)

        // A published complete ordinary read is the one shape the separate command
        // may consider.
        let ordinaryPublished = PenImportBatchRecord(
            batchID: UUID(),
            state: .published,
            pages: [page],
            strokeCount: 13,
            dotCount: 100
        )
        XCTAssertTrue(ordinaryPublished.isPublicationRetryable)
        XCTAssertFalse(ordinaryPublished.blocksCommandDeletionScope)

        // A deleting batch is never eligible for a separate command, whatever its
        // publication or completion says.
        for completion in ImportBatchCompletion.allCases {
            let deleting = PenImportBatchRecord(
                batchID: UUID(),
                state: .published,
                kind: .deleting,
                completion: completion,
                pages: [page],
                strokeCount: 13,
                dotCount: 100,
                packets: [packet]
            )
            XCTAssertTrue(deleting.isDeletingTransfer)
            XCTAssertTrue(deleting.hasDurablePackets)
            XCTAssertTrue(deleting.blocksCommandDeletionScope)
            XCTAssertTrue(deleting.isPublicationRetryable)
        }

        // A deleting batch with no durable packet has nothing to publish.
        let emptyDeleting = PenImportBatchRecord(
            batchID: UUID(),
            state: .committed,
            kind: .deleting,
            completion: .inProgress,
            pages: [page],
            strokeCount: 0,
            dotCount: 0
        )
        XCTAssertFalse(emptyDeleting.hasDurablePackets)
        XCTAssertFalse(emptyDeleting.isPublicationRetryable)

        // An ordinary batch whose transfer stopped short still blocks a shared page,
        // even after its publication succeeded.
        let ordinaryPartial = PenImportBatchRecord(
            batchID: UUID(),
            state: .published,
            completion: .partial,
            pages: [page],
            strokeCount: 13,
            dotCount: 100
        )
        XCTAssertFalse(ordinaryPartial.isTransferComplete)
        XCTAssertTrue(ordinaryPartial.blocksCommandDeletionScope)
    }

    func testDeletingPacketReportsItsPagesInCanonicalOrder() {
        let pages = [
            PageIdentity(section: 3, owner: 27, book: 700, page: 37),
            PageIdentity(section: 3, owner: 27, book: 700, page: 36),
            PageIdentity(section: 3, owner: 27, book: 700, page: 37),
        ]
        let packet = PenDeletingPacket(
            batchID: UUID(),
            sectionOwnerID: 27,
            noteID: 700,
            packetID: 1,
            strokes: pages.map { stroke(page: $0) },
            isEndPacket: false
        )

        XCTAssertEqual(packet.pages.map(\.page), [36, 37])
    }

    // MARK: - Outcomes

    func testAcknowledgedPrefixOutcomeReportsItsBound() {
        let complete = PenCleanupOutcome.acknowledgedPrefix(
            packetCount: 2,
            isComplete: true,
            removalUncertain: false,
            reachedEndPacket: true
        )
        XCTAssertTrue(complete.isReclaimed)
        XCTAssertTrue(complete.summary.contains("2 acknowledged packets"), complete.summary)
        XCTAssertTrue(complete.summary.contains("library copy remains available"), complete.summary)
        XCTAssertFalse(
            complete.summary.contains("whole note"),
            "the outcome never claims an unproven trigger"
        )

        let partial = PenCleanupOutcome.acknowledgedPrefix(
            packetCount: 1,
            isComplete: false,
            removalUncertain: true,
            reachedEndPacket: false
        )
        XCTAssertTrue(partial.isReclaimed)
        XCTAssertTrue(partial.summary.contains("1 acknowledged packet"), partial.summary)
        XCTAssertTrue(partial.summary.contains("the pen may still hold the remainder"), partial.summary)
        XCTAssertTrue(
            partial.summary.contains("acknowledgement was not confirmed"),
            partial.summary
        )

        // A transfer that reached its last packet but whose completion could not be
        // recorded holds nothing back on the pen, so the summary must not blame a short
        // transfer for what is a storage failure.
        let unrecorded = PenCleanupOutcome.acknowledgedPrefix(
            packetCount: 3,
            isComplete: false,
            removalUncertain: false,
            reachedEndPacket: true
        )
        XCTAssertTrue(unrecorded.isReclaimed)
        XCTAssertTrue(
            unrecorded.summary.contains("the pen holds no remainder of it"),
            unrecorded.summary
        )
        XCTAssertTrue(
            unrecorded.summary.contains("completion could not be recorded"),
            unrecorded.summary
        )
        XCTAssertFalse(
            unrecorded.summary.contains("the pen may still hold the remainder"),
            "a finished transfer is not reported as a short one"
        )

        // No acknowledged packet means nothing was reclaimed, whatever the flags
        // say: the acknowledgement bound is what the outcome reports.
        XCTAssertFalse(
            PenCleanupOutcome.acknowledgedPrefix(
                packetCount: 0,
                isComplete: false,
                removalUncertain: false,
                reachedEndPacket: false
            ).isReclaimed
        )
    }

    func testDeletingReadRefusalReasonsNameEachPrecondition() {
        XCTAssertTrue(
            PenDeletingReadRefusal.noExportRequested.reason.contains("no export"),
            PenDeletingReadRefusal.noExportRequested.reason
        )
        XCTAssertTrue(
            PenDeletingReadRefusal.notConfirmedForThisSync.reason.contains("confirmation"),
            PenDeletingReadRefusal.notConfirmedForThisSync.reason
        )
        XCTAssertTrue(
            PenDeletingReadRefusal.durableStorageUnavailable(reason: "the file is read-only")
                .reason.contains("the file is read-only")
        )
        XCTAssertEqual(
            PenDeletingReadRefusal.evidenceClosed(reason: "the gate is closed").reason,
            "the gate is closed"
        )
        XCTAssertFalse(
            PenDeletingReadRefusal.noExportRequested.reason.contains("0x25"),
            "a transfer refusal never names the separate command"
        )
    }

    // MARK: - Helpers

    private func stroke(page: PageIdentity) -> Stroke {
        Stroke(
            page: page,
            originTime: .reliable(milliseconds: 1_700_000_000_000),
            points: [PenPoint(x: 1, y: 2, penTimeOffsetMilliseconds: 0, pressure: 3)],
            source: .offline
        )
    }

    private func assertRefusal(
        _ result: Result<PenDeletingReadAuthorization, PenDeletingReadRefusal>,
        is expected: PenDeletingReadRefusal,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let authorization):
            XCTFail("expected \(expected), got an authorization for \(authorization.requiredIdentity)", file: file, line: line)
        case .failure(let refusal):
            XCTAssertEqual(refusal, expected, file: file, line: line)
        }
    }
}

/// A barrier that does nothing, so a test can build an available storage value
/// without a database.
private actor NoopBarrier: PenDeletingPacketBarrier {
    func beginDeletingRead(notes: [PenDeletingReadNote]) async throws -> UUID { UUID() }

    func commitDeletingPacket(
        _ packet: PenDeletingPacket
    ) async throws -> PenDeletingPacketCommitResult {
        PenDeletingPacketCommitResult(
            committedPacketCount: 1,
            committedStrokeCount: packet.strokes.count,
            committedDotCount: packet.strokes.reduce(0) { $0 + $1.points.count },
            addedStrokeCount: packet.strokes.count,
            duplicateStrokeCount: 0,
            isEndPacket: packet.isEndPacket
        )
    }

    func finishDeletingRead(batchID: UUID, isComplete: Bool) async throws {}

    func failDeletingRead(batchID: UUID) async throws {}
}

extension Result {
    /// The success value, or `nil` when the result is a failure.
    fileprivate var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }

    /// The failure value, or `nil` when the result is a success.
    fileprivate var failureValue: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}
