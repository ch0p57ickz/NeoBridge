import Foundation
import NeoCore
import NeoExport
import NeoProtocol
import NeoStorage
import XCTest

import NeoBridgeIntegration

/// End-to-end deleting-read scenarios over a sanitized fixture, a fake transport,
/// and the real SQLite library as the durable packet barrier.
///
/// Each scenario runs the whole portable path with no platform type and no radio,
/// so it runs on Linux as well as macOS. The barrier is the real library rather
/// than a recording stub, so what the acknowledgement bound promises — a packet is
/// acknowledged only after its strokes are durable — is verified against the
/// storage the app actually uses.
final class DeletingReadIntegrationTests: XCTestCase {
    // MARK: - The deleting read

    func testADeletingReadCommitsEveryPacketBeforeItsAcknowledgementAndPublishes() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace()
        defer { workspace.remove() }
        let log = OrderedLog()
        let transport = AbandoningPenTransport(chunks: try fixture.decodedChunks(), log: log)
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: workspace.library,
            onDeletingPacketCommitted: { packetID, strokeCount in
                log.record("commit(\(packetID),\(strokeCount))")
            }
        )

        let result = try await session.run()

        // Every commit precedes its own acknowledgement, and the two notes' packets
        // are committed in order.
        XCTAssertEqual(
            log.values,
            [
                "commit(1,1)", "ack(1)",
                "commit(2,1)", "ack(2)",
                "commit(3,1)", "ack(3)",
                "commit(1,1)", "ack(1)",
            ],
            "a packet must be durable before the pen is told to continue"
        )

        let deleting = try XCTUnwrap(result.deletingTransfer)
        XCTAssertTrue(deleting.isComplete)
        XCTAssertFalse(deleting.acknowledgementUncertain)
        XCTAssertEqual(deleting.committedPacketCount, 4)
        XCTAssertEqual(deleting.committedStrokeCount, 4)
        XCTAssertEqual(deleting.addedStrokeCount, 4)
        XCTAssertEqual(deleting.duplicateStrokeCount, 0)
        XCTAssertEqual(deleting.pages.count, 4)

        // The batch is the durable record of what the pen was told it could remove.
        let record = try await workspace.library.batch(id: deleting.batchID)
        XCTAssertEqual(record?.kind, .deleting)
        XCTAssertEqual(record?.state, .committed)
        XCTAssertEqual(record?.completion, .complete)
        XCTAssertEqual(record?.strokeCount, 4)
        XCTAssertEqual(record?.packets.count, 4)
        XCTAssertEqual(record?.packets.map(\.strokeCount), [1, 1, 1, 1])
        XCTAssertTrue(record?.packets.last?.isEndPacket ?? false)

        // The transfer itself is the deletion bound: no separate command is sent.
        let commands = OutboundCommands.decode(transport.sentChunks)
        XCTAssertFalse(commands.contains(.deleteOfflineNoteRequest))
        XCTAssertFalse(commands.contains(.deleteOfflinePageRequest))

        // The committed pages publish from storage, and publication does not change
        // the transfer's completion.
        let report = try await workspace.importer.publish(
            deleting.batchID,
            request: workspace.exportRequest(pages: deleting.pages)
        )
        XCTAssertTrue(report.succeeded)
        let published = try await workspace.library.batch(id: deleting.batchID)
        XCTAssertEqual(published?.state, .published)
        XCTAssertEqual(published?.completion, .complete)
        XCTAssertFalse(try workspace.exportedFiles().isEmpty)

        // A separate command cleanup refuses a deleting batch, whatever its state.
        let sender = RecordingDeletionSender()
        let cleanup = try await workspace.importer.requestCleanup(
            deleting.batchID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        guard case .skipped(let reason) = cleanup else {
            return XCTFail("expected a deleting batch to refuse the command path, got \(cleanup)")
        }
        XCTAssertTrue(reason.contains("transfer cleanup"), reason)
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "a deleting batch must never reach the pen as a command")
        let outstanding = try await workspace.library.outstandingScopes()
        XCTAssertEqual(outstanding, [], "a deleting batch must journal no command scope")
    }

    func testNoExportDeletingIntentFallsBackAndSendsNoDeletingOption() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace()
        defer { workspace.remove() }
        let transport = AbandoningPenTransport(chunks: try fixture.decodedChunks())
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(requestedExport: false),
            packetBarrier: workspace.library
        )

        let result = try await session.run()

        // The route closed, so the read ran non-destructively and named the blocker
        // rather than failing: the pen's data is still readable.
        XCTAssertEqual(
            result.deletingReadRefusal,
            PenDeletingReadRefusal.noExportRequested.reason
        )
        XCTAssertNil(result.deletingTransfer, "no deleting batch may be opened")
        XCTAssertEqual(result.notes.count, 2, "the read itself must still complete")

        // No option 0x01 was sent, and no deleting batch exists in the library.
        let options = OutboundCommands.decode(transport.sentChunks)
        XCTAssertEqual(
            options.filter { $0 == .offlineDataRequest1 }.count,
            2,
            "one 0x23 per discovered note, all non-deleting"
        )
        let optionsSent = OutboundCommands.options(transport.sentChunks)
        XCTAssertFalse(
            optionsSent.contains(OfflineTransferOption.nextAndDelete.rawValue),
            "a read with no export must never request the deleting transfer"
        )
        let pages = try await workspace.library.pages()
        XCTAssertEqual(pages, [], "a non-destructive read stores nothing by itself")
    }

    // MARK: - Overlapping replay

    func testAFreshDeletingReadRecoversWithoutDuplicatingCommittedStrokes() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace()
        defer { workspace.remove() }
        let chunks = try fixture.decodedChunks()

        let first = try await deletingRead(chunks, workspace: workspace)
        let firstID = try XCTUnwrap(first.deletingTransfer?.batchID)

        // A fresh read of the same pen: the strokes are already stored, so the new
        // batch adds nothing and the library is not duplicated.
        let second = try await deletingRead(chunks, workspace: workspace)
        let secondID = try XCTUnwrap(second.deletingTransfer?.batchID)
        XCTAssertNotEqual(secondID, firstID, "a fresh read starts a new batch")

        let secondTransfer = try XCTUnwrap(second.deletingTransfer)
        XCTAssertEqual(secondTransfer.committedStrokeCount, 0)
        XCTAssertEqual(secondTransfer.addedStrokeCount, 0)
        XCTAssertEqual(secondTransfer.duplicateStrokeCount, 4)
        XCTAssertEqual(secondTransfer.pages.count, 4, "the replayed packets still name their pages")

        var stored = 0
        for page in try await workspace.library.pages() {
            stored += try await workspace.library.strokes(on: page).count
        }
        XCTAssertEqual(stored, fixture.expectedStrokeCount, "a replay must not duplicate the library")

        // Both batches keep their own durable prefix and their own packet rows.
        let firstRecord = try await workspace.library.batch(id: firstID)
        XCTAssertEqual(firstRecord?.strokeCount, 4)
        XCTAssertEqual(firstRecord?.packets.count, 4)
        let secondRecord = try await workspace.library.batch(id: secondID)
        XCTAssertEqual(secondRecord?.strokeCount, 0)
        XCTAssertEqual(secondRecord?.packets.count, 4)
        XCTAssertEqual(secondRecord?.kind, .deleting)
    }

    // MARK: - Pen abandonment during a commit

    func testAPenThatAbandonsDuringACommitLeavesAPartialButRecoverableBatch() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace()
        defer { workspace.remove() }
        let chunks = try fixture.decodedChunks()
        let log = OrderedLog()
        let transport = AbandoningPenTransport(
            chunks: chunks,
            abandonAcknowledgements: true,
            log: log
        )
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: workspace.library,
            onDeletingPacketCommitted: { packetID, strokeCount in
                log.record("commit(\(packetID),\(strokeCount))")
            }
        )

        let result = try await session.run()

        // The packet's bytes arrived and its commit ran, so the packet is durable
        // even though no acknowledgement reached the pen.
        XCTAssertEqual(
            log.values,
            ["commit(1,1)", "ack-abandoned(1)"],
            "the commit must precede the acknowledgement it never delivered"
        )

        let deleting = try XCTUnwrap(result.deletingTransfer)
        XCTAssertFalse(deleting.isComplete)
        XCTAssertTrue(deleting.acknowledgementUncertain, "the acknowledgement never arrived")
        XCTAssertEqual(deleting.committedPacketCount, 1)
        XCTAssertEqual(deleting.committedStrokeCount, 1)
        XCTAssertNotNil(deleting.reason)

        // The batch is partial and keeps the acknowledged prefix.
        let record = try await workspace.library.batch(id: deleting.batchID)
        XCTAssertEqual(record?.kind, .deleting)
        XCTAssertEqual(record?.state, .committed)
        XCTAssertEqual(record?.completion, .partial)
        XCTAssertEqual(record?.strokeCount, 1)
        XCTAssertEqual(record?.packets.count, 1)
        let stored = try await workspace.library.strokes(on: try XCTUnwrap(deleting.pages.first))
        XCTAssertEqual(stored.count, 1, "the committed packet must stay readable")

        // A fresh read recovers the remainder without duplicating the prefix.
        let recovered = try await deletingRead(chunks, workspace: workspace)
        let recoveredTransfer = try XCTUnwrap(recovered.deletingTransfer)
        XCTAssertTrue(recoveredTransfer.isComplete)
        XCTAssertEqual(recoveredTransfer.addedStrokeCount, 3)
        XCTAssertEqual(recoveredTransfer.duplicateStrokeCount, 1)
        XCTAssertNotEqual(recoveredTransfer.batchID, deleting.batchID)

        var total = 0
        for page in try await workspace.library.pages() {
            total += try await workspace.library.strokes(on: page).count
        }
        XCTAssertEqual(total, fixture.expectedStrokeCount)

        // The interrupted batch stays partial: the remainder lives in the new one.
        let interrupted = try await workspace.library.batch(id: deleting.batchID)
        XCTAssertEqual(interrupted?.completion, .partial)
    }

    // MARK: - Interruption

    func testAnInterruptedDeletingReadCommitsNoPacketAndFailsTheBatchItOpened() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace()
        defer { workspace.remove() }
        let chunks = try fixture.decodedChunks()

        // The handshake, note list, page list, and data info arrive; the link drops
        // before the first data packet.
        let transport = FakePenTransport(
            chunks: Array(chunks.prefix(4)),
            failure: IntegrationTestError.connectionDropped
        )
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: workspace.library
        )

        do {
            _ = try await session.run()
            XCTFail("expected the interrupted deleting read to fail")
        } catch is PenSessionError {
            // Expected: before the first commit there is no durable prefix, so the
            // failure is ordinary rather than a partial result.
        }

        let pages = try await workspace.library.pages()
        XCTAssertEqual(pages, [], "an interrupted read must store no stroke")
        XCTAssertEqual(try workspace.exportedFiles(), [])

        // The batch opened before the first 0x23 has no packet, so it can neither
        // publish nor be reclaimed. It must not be left claiming an in-progress
        // transfer either: the read that opened it has ended, so the row is marked
        // failed and kept, which is what a later diagnosis reads.
        let failed = try await workspace.library.batches(in: .failed)
        XCTAssertEqual(failed.count, 1)
        let opened = try XCTUnwrap(failed.first)
        XCTAssertEqual(opened.kind, .deleting)
        XCTAssertEqual(opened.completion, .partial)
        XCTAssertEqual(opened.packets, [])
        XCTAssertEqual(opened.pages, [])
        XCTAssertFalse(opened.isPublicationRetryable)
        XCTAssertFalse(opened.isTransferComplete)

        let inProgress = try await workspace.library.batches(in: .committed)
        XCTAssertEqual(inProgress, [], "no deleting batch may stay in progress with no packet")
    }

    // MARK: - Export failure and partial publication

    func testAFailedExportLeavesTheDeletingBatchRetryable() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace(publisher: FailingExportPublisher())
        defer { workspace.remove() }

        let result = try await deletingRead(try fixture.decodedChunks(), workspace: workspace)
        let deleting = try XCTUnwrap(result.deletingTransfer)

        let report = try await workspace.importer.publish(
            deleting.batchID,
            request: workspace.exportRequest(pages: deleting.pages)
        )
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(try workspace.exportedFiles().isEmpty, "a failed export writes no file")

        // The save is unaffected and the batch can still publish from its rows.
        let record = try await workspace.library.batch(id: deleting.batchID)
        XCTAssertEqual(record?.state, .committed)
        XCTAssertEqual(record?.completion, .complete)
        XCTAssertTrue(record?.isPublicationRetryable ?? false)
        XCTAssertEqual(record?.strokeCount, 4)

        // A later attempt with a working publisher publishes the stored pages.
        let working = workspace.importer(publisher: FilePenExportPublisher())
        let retried = try await working.retryExport(
            batchID: deleting.batchID,
            request: workspace.exportRequest(pages: deleting.pages)
        )
        XCTAssertTrue(retried.succeeded)
        let published = try await workspace.library.batch(id: deleting.batchID)
        XCTAssertEqual(published?.state, .published)
        XCTAssertEqual(published?.completion, .complete)
    }

    func testAPublishedPartialDeletingBatchBlocksASeparateCommandDeletion() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace(policy: PenCleanupPolicy(evidence: openDeletionGate()))
        defer { workspace.remove() }
        let chunks = try fixture.decodedChunks()

        // The deleting read stops after its first packet, so its batch is partial.
        let transport = AbandoningPenTransport(chunks: chunks, abandonAcknowledgements: true)
        let session = PenSession(
            transport: transport,
            deletingRead: deletingIntent(),
            packetBarrier: workspace.library
        )
        let result = try await session.run()
        let deleting = try XCTUnwrap(result.deletingTransfer)
        let page = try XCTUnwrap(deleting.pages.first)

        // Its committed pages publish in full, which must not complete the read.
        let report = try await workspace.importer.publish(
            deleting.batchID,
            request: workspace.exportRequest(pages: deleting.pages)
        )
        XCTAssertTrue(report.succeeded)
        let published = try await workspace.library.batch(id: deleting.batchID)
        XCTAssertEqual(published?.state, .published)
        XCTAssertEqual(published?.completion, .partial)

        // An ordinary read over the same page publishes in full too.
        let ordinary = try await workspace.importer.importRead(
            PenReadTransfer(
                strokes: [
                    Stroke(
                        page: page,
                        originTime: .reliable(milliseconds: 1),
                        points: [
                            PenPoint(x: 11, y: 22, penTimeOffsetMilliseconds: 0, pressure: 3)
                        ],
                        source: .offline
                    )
                ],
                noteCount: 1
            ),
            export: workspace.exportRequest(pages: [page])
        )
        let ordinaryID = try XCTUnwrap(ordinary.save?.batchID)
        XCTAssertTrue(ordinary.export?.succeeded ?? false)

        // The published but incomplete deleting batch still holds that page, so the
        // separate command is refused.
        let sender = RecordingDeletionSender()
        let cleanup = try await workspace.importer.requestCleanup(
            ordinaryID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        guard case .skipped(let reason) = cleanup else {
            return XCTFail("expected the shared page to block the command, got \(cleanup)")
        }
        XCTAssertTrue(reason.contains("has not completed"), reason)
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "a page an incomplete deleting read covers must stay on the pen")
    }

    // MARK: - Helpers

    /// A deleting read intent with the recorded pen's evidence.
    private func deletingIntent(
        requestedExport: Bool = true,
        confirmedForThisSync: Bool = true,
        durablePacketStorageAvailable: Bool = true
    ) -> PenDeletingReadIntent {
        PenDeletingReadIntent(
            policy: PenCleanupPolicy(),
            requestedExport: requestedExport,
            confirmedForThisSync: confirmedForThisSync,
            durablePacketStorageAvailable: durablePacketStorageAvailable
        )
    }

    /// Runs one deleting read over the fixture with the workspace's real library.
    private func deletingRead(
        _ chunks: [[UInt8]],
        workspace: IntegrationWorkspace
    ) async throws -> PenSessionResult {
        let session = PenSession(
            transport: FakePenTransport(chunks: chunks),
            deletingRead: deletingIntent(),
            packetBarrier: workspace.library
        )
        return try await session.run()
    }
}
