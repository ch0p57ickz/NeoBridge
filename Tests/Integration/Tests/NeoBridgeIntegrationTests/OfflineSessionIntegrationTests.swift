import Foundation
import NeoCore
import NeoExport
import NeoProtocol
import NeoStorage
import XCTest

import NeoBridgeIntegration

/// End-to-end scenarios over a sanitized fixture and a fake transport.
///
/// Each scenario runs the whole portable path — session, storage, export — with
/// no platform type and no radio, so it runs on Linux as well as macOS.
final class OfflineSessionIntegrationTests: XCTestCase {
    // MARK: - Offline import

    func testOfflineSessionImportsAndExportsEveryPage() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace()
        defer { workspace.remove() }
        let chunks = try fixture.decodedChunks()

        // An empty page list asks the importer to publish the batch's own pages,
        // which is what the app's default request does.
        let session = try await OfflineSessionImport(importer: workspace.importer).run(
            transport: FakePenTransport(chunks: chunks),
            export: workspace.exportRequest(pages: [])
        )

        XCTAssertEqual(session.result.notes.count, 2)
        XCTAssertEqual(session.result.strokeCount, fixture.expectedStrokeCount)
        XCTAssertEqual(session.outcome.save?.strokeCount, fixture.expectedStrokeCount)
        XCTAssertEqual(session.outcome.save?.insertion.addedStrokeCount, fixture.expectedStrokeCount)
        XCTAssertTrue(session.outcome.isSaved)

        let expectedPage = try XCTUnwrap(fixture.expectedPage)
        let pages = Set(session.result.strokes.map(\.page))
        XCTAssertTrue(
            pages.contains(
                PageIdentity(
                    section: expectedPage.section,
                    owner: expectedPage.owner,
                    book: expectedPage.book,
                    page: expectedPage.page
                )
            ),
            "the captured page must survive the whole path"
        )

        // Every page that carried a stroke produces one file per format, and no
        // page that carried none produces a file.
        var expected: Set<String> = []
        for page in pages {
            let base = PageExportDocument(page: page, strokes: []).fileBaseName
            for format in PenExportFormat.allCases {
                expected.insert("\(base).\(format.fileExtension)")
            }
        }
        XCTAssertEqual(Set(try workspace.exportedFiles()), expected)
    }

    func testDuplicateReplayIsDeduplicated() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace()
        defer { workspace.remove() }
        let chunks = try fixture.decodedChunks()
        let importer = OfflineSessionImport(importer: workspace.importer)

        let first = try await importer.run(transport: FakePenTransport(chunks: chunks), export: nil)
        let second = try await importer.run(transport: FakePenTransport(chunks: chunks), export: nil)

        XCTAssertEqual(first.outcome.save?.insertion.addedStrokeCount, fixture.expectedStrokeCount)
        XCTAssertEqual(second.outcome.save?.insertion.addedStrokeCount, 0)
        XCTAssertEqual(second.outcome.save?.insertion.duplicateStrokeCount, fixture.expectedStrokeCount)

        // The replay must not double the library.
        var stored = 0
        for page in try await workspace.library.pages() {
            stored += try await workspace.library.strokes(on: page).count
        }
        XCTAssertEqual(stored, fixture.expectedStrokeCount)
    }

    // MARK: - Interruption and recovery

    func testInterruptedSyncCommitsNothing() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace()
        defer { workspace.remove() }
        let chunks = try fixture.decodedChunks()

        // Deliver the handshake and the discovery responses, then drop the link
        // before the transfer ends.
        let transport = FakePenTransport(
            chunks: Array(chunks.prefix(5)),
            failure: IntegrationTestError.connectionDropped
        )

        do {
            _ = try await OfflineSessionImport(importer: workspace.importer).run(
                transport: transport,
                export: nil
            )
            XCTFail("expected the interrupted session to fail")
        } catch is PenSessionError {
            // Expected: a partial transfer is never a completed read.
        } catch {
            XCTFail("expected a session error, got \(error)")
        }

        let pages = try await workspace.library.pages()
        XCTAssertEqual(pages, [])
        XCTAssertEqual(try workspace.exportedFiles(), [])
    }

    func testSyncRecoversAfterInterruption() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace()
        defer { workspace.remove() }
        let chunks = try fixture.decodedChunks()
        let importer = OfflineSessionImport(importer: workspace.importer)

        let interrupted = FakePenTransport(
            chunks: Array(chunks.prefix(5)),
            failure: IntegrationTestError.connectionDropped
        )
        do {
            _ = try await importer.run(transport: interrupted, export: nil)
            XCTFail("expected the interrupted session to fail")
        } catch {
            // Expected: nothing is committed.
        }
        let pagesAfterInterruption = try await workspace.library.pages()
        XCTAssertEqual(pagesAfterInterruption, [])

        // A fresh session over a fresh transport completes and commits.
        let recovered = try await importer.run(transport: FakePenTransport(chunks: chunks), export: nil)
        XCTAssertEqual(recovered.outcome.save?.insertion.addedStrokeCount, fixture.expectedStrokeCount)
        XCTAssertEqual(recovered.outcome.save?.strokeCount, fixture.expectedStrokeCount)
    }

    // MARK: - Cleanup and retention

    func testCleanupReclaimsThePenCopyOnlyAfterAVerifiedImportAndExport() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace(policy: PenCleanupPolicy(evidence: openDeletionGate()))
        defer { workspace.remove() }
        let sender = RecordingDeletionSender()

        let session = try await OfflineSessionImport(importer: workspace.importer).run(
            transport: FakePenTransport(chunks: try fixture.decodedChunks()),
            export: workspace.exportRequest(pages: []),
            cleanup: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        let save = try XCTUnwrap(session.outcome.save)
        let cleanup = try XCTUnwrap(session.cleanup)
        guard case .reclaimed(let pageCount) = cleanup else {
            return XCTFail("expected the pen's copy to be reclaimed, got \(cleanup)")
        }
        XCTAssertEqual(pageCount, save.pages.count)

        // The deletion targeted exactly the batch's own committed pages.
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent.map(\.batchID), [save.batchID])
        XCTAssertEqual(sent.first?.pages, save.pages)

        // The library copy survives the deletion and can be published again.
        let stored = try await workspace.library.pages()
        XCTAssertEqual(Set(stored), Set(save.pages), "the library copy must remain readable")
        let report = try await workspace.importer.retryExport(
            batchID: save.batchID,
            request: workspace.exportRequest(pages: save.pages)
        )
        XCTAssertTrue(report.succeeded, "a deleted pen page must still be exportable from the library")
        XCTAssertFalse(try workspace.exportedFiles().isEmpty)
    }

    func testTheClosedGateRetainsThePenCopyAndReportsWhyCleanupWasSkipped() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace()
        defer { workspace.remove() }
        let sender = RecordingDeletionSender()

        let session = try await OfflineSessionImport(importer: workspace.importer).run(
            transport: FakePenTransport(chunks: try fixture.decodedChunks()),
            export: workspace.exportRequest(pages: []),
            cleanup: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        // The read still succeeds and retains its library copy.
        XCTAssertTrue(session.outcome.isSaved)
        let cleanup = try XCTUnwrap(session.cleanup)
        guard case .skipped(let reason) = cleanup else {
            return XCTFail("expected the closed gate to skip cleanup, got \(cleanup)")
        }
        XCTAssertTrue(reason.contains("deletion evidence gate"), reason)

        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "a closed gate must not send a deletion command")
        let outstanding = try await workspace.library.outstandingScopes()
        XCTAssertEqual(outstanding, [])
    }

    func testRetentionByChoiceSendsNoDeletionAndJournalsNothing() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace(policy: PenCleanupPolicy(evidence: openDeletionGate()))
        defer { workspace.remove() }
        let sender = RecordingDeletionSender()

        let session = try await OfflineSessionImport(importer: workspace.importer).run(
            transport: FakePenTransport(chunks: try fixture.decodedChunks()),
            export: workspace.exportRequest(pages: []),
            cleanup: PenCleanupRequest(mode: .keepOnPen, sender: sender)
        )

        XCTAssertEqual(session.cleanup, .retainedByChoice)
        XCTAssertEqual(session.outcome.save?.insertion.addedStrokeCount, fixture.expectedStrokeCount)
        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "retention must not send a deletion command")
        let outstanding = try await workspace.library.outstandingScopes()
        XCTAssertEqual(outstanding, [], "retention must journal no cleanup request")
    }

    func testAnInterruptedTransferSendsNoDeletionAndJournalsNothing() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace(policy: PenCleanupPolicy(evidence: openDeletionGate()))
        defer { workspace.remove() }
        let sender = RecordingDeletionSender()
        let chunks = try fixture.decodedChunks()

        let transport = FakePenTransport(
            chunks: Array(chunks.prefix(5)),
            failure: IntegrationTestError.connectionDropped
        )
        do {
            _ = try await OfflineSessionImport(importer: workspace.importer).run(
                transport: transport,
                export: workspace.exportRequest(pages: []),
                cleanup: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
            )
            XCTFail("expected the interrupted session to fail")
        } catch is PenSessionError {
            // Expected: a partial transfer is never a completed read.
        }

        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "an interrupted transfer must not delete")
        let outstanding = try await workspace.library.outstandingScopes()
        XCTAssertEqual(outstanding, [])
        let pages = try await workspace.library.pages()
        XCTAssertEqual(pages, [])
    }

    func testAFailedExportRetainsThePenCopyAndSendsNoDeletion() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace(
            publisher: FailingExportPublisher(),
            policy: PenCleanupPolicy(evidence: openDeletionGate())
        )
        defer { workspace.remove() }
        let sender = RecordingDeletionSender()

        let session = try await OfflineSessionImport(importer: workspace.importer).run(
            transport: FakePenTransport(chunks: try fixture.decodedChunks()),
            export: workspace.exportRequest(pages: []),
            cleanup: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )

        XCTAssertFalse(session.outcome.export?.succeeded ?? true)
        let cleanup = try XCTUnwrap(session.cleanup)
        guard case .skipped(let reason) = cleanup else {
            return XCTFail("expected a failed export to retain the pen copy, got \(cleanup)")
        }
        XCTAssertTrue(reason.contains("no export published in full"), reason)

        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent, [], "a failed export must not delete")
    }

    func testAnEarlierPublishedNoteIsReclaimedWhileALaterNoteFails() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let chunks = try fixture.decodedChunks()
        let workspace = try IntegrationWorkspace(policy: PenCleanupPolicy(evidence: openDeletionGate()))
        defer { workspace.remove() }
        let sender = RecordingDeletionSender()
        let importer = OfflineSessionImport(importer: workspace.importer)

        // The earlier note completes: its transfer, import, and export succeed.
        let earlierChunks = try Self.oneNoteSession(
            chunks,
            note: Self.note700,
            frames: [0, 1, 2, 3, 4, 5, 6]
        )
        let earlier = try await importer.run(
            transport: FakePenTransport(chunks: earlierChunks),
            export: workspace.exportRequest(pages: [])
        )
        let earlierID = try XCTUnwrap(earlier.outcome.save?.batchID)

        // The later note's export fails, so its sync has not completed. Its page
        // set is disjoint from the earlier note's, which the fixture guarantees.
        let laterChunks = try Self.oneNoteSession(
            chunks,
            note: Self.note701,
            frames: [0, 1, 7, 8, 9]
        )
        let failing = workspace.importer(publisher: FailingExportPublisher())
        let later = try await OfflineSessionImport(importer: failing).run(
            transport: FakePenTransport(chunks: laterChunks),
            export: workspace.exportRequest(pages: [])
        )
        let laterID = try XCTUnwrap(later.outcome.save?.batchID)
        XCTAssertFalse(later.outcome.export?.succeeded ?? true)

        // The completed note is reclaimed, and only on its own pages.
        let reclaimed = try await workspace.importer.requestCleanup(
            earlierID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        guard case .reclaimed(let pageCount) = reclaimed else {
            return XCTFail("expected the completed note to be reclaimed, got \(reclaimed)")
        }
        XCTAssertEqual(pageCount, earlier.outcome.save?.pages.count)

        let sent = await sender.calls.allScopes
        XCTAssertEqual(sent.count, 1, "only the completed note may be sent")
        XCTAssertEqual(sent.first?.pages, earlier.outcome.save?.pages)

        // The incomplete note is retained.
        let retained = try await workspace.importer.requestCleanup(
            laterID,
            request: PenCleanupRequest(mode: .deleteAfterAcknowledge, sender: sender)
        )
        guard case .skipped(let reason) = retained else {
            return XCTFail("expected the incomplete note to be retained, got \(retained)")
        }
        XCTAssertTrue(reason.contains("no export published in full"), reason)
        let stillSent = await sender.calls.allScopes
        XCTAssertEqual(stillSent.count, 1, "the incomplete note must not reach the pen")
    }

    // MARK: - Deletion stays disabled

    func testSessionSendsNoDeletionCommand() async throws {
        let fixture = try IntegrationFixtures.offlineSession()
        let workspace = try IntegrationWorkspace()
        defer { workspace.remove() }
        let transport = FakePenTransport(chunks: try fixture.decodedChunks())

        _ = try await OfflineSessionImport(importer: workspace.importer).run(
            transport: transport,
            export: nil
        )

        let commands = OutboundCommands.decode(transport.sentChunks)
        XCTAssertFalse(commands.contains(.deleteOfflineNoteRequest))
        XCTAssertFalse(commands.contains(.deleteOfflinePageRequest))
        XCTAssertTrue(commands.contains(.versionInfo))
        XCTAssertTrue(commands.contains(.offlineNoteListRequest))
        XCTAssertTrue(commands.contains(.responseOfflineData), "each data packet is acknowledged")
    }

    // MARK: - No device identity in output

    func testSessionOutputCarriesNoDeviceIdentity() async throws {
        let workspace = try IntegrationWorkspace()
        defer { workspace.remove() }

        // Replace the version response's device name and sub-name with sentinels,
        // so a leak of the pen's identity into a file would be visible.
        let chunks = try sessionChunksWithIdentitySentinel()
        let transport = FakePenTransport(chunks: chunks)

        _ = try await OfflineSessionImport(importer: workspace.importer).run(
            transport: transport,
            export: workspace.exportRequest(pages: [])
        )

        let text = try workspace.exportedText()
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("SENTINEL"), "the device name must not reach a file")
        XCTAssertFalse(text.contains("SENTINEL_SUB_1"), "the sub-name must not reach a file")
        XCTAssertFalse(text.lowercased().contains("bluetooth"))
        XCTAssertFalse(text.lowercased().contains("serialnumber"))
    }

    // MARK: - Helpers

    /// The fixture note whose pages are 1, 16, and 17.
    private static let note700 = (section: UInt8(3), owner: UInt32(27), id: UInt32(700))

    /// The fixture note whose only page is 2, disjoint from `note700`.
    private static let note701 = (section: UInt8(3), owner: UInt32(27), id: UInt32(701))

    /// The fixture's chunks with its note list rewritten to one note.
    ///
    /// The fixture lists two notes and carries each one's page list, info, and
    /// data packets in order. Rewriting the list makes a session read exactly the
    /// frames of one note, so two sessions over disjoint pages describe two notes
    /// without a second fixture.
    ///
    /// - Parameters:
    ///   - chunks: The fixture's chunks, in trace order.
    ///   - note: The one note the rewritten list reports.
    ///   - frames: The chunk indices to keep. Index 1 is replaced by the rewritten
    ///     note list.
    /// - Returns: A stream a session reads as one note.
    private static func oneNoteSession(
        _ chunks: [[UInt8]],
        note: (section: UInt8, owner: UInt32, id: UInt32),
        frames: [Int]
    ) throws -> [[UInt8]] {
        var payload: [UInt8] = [1, 0]
        let sectionOwner = UInt32(note.section) << 24 | note.owner
        for value in [sectionOwner, note.id] {
            payload.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
        }

        guard
            let list = PenFrameEncoder.encode(
                command: .responseOfflineNoteList,
                payload: payload,
                errorCode: 0
            )
        else {
            throw IntegrationError.missingFixture("the note list could not be re-encoded")
        }

        return frames.map { index in
            index == 1 ? list : chunks[index]
        }
    }

    /// The session fixture whose version response names sentinel devices.
    private func sessionChunksWithIdentitySentinel() throws -> [[UInt8]] {
        let fixture = try IntegrationFixtures.offlineSession()
        var chunks = try fixture.decodedChunks()

        var decoder = PenFrameDecoder()
        guard case .frame(let frame)? = decoder.ingest(chunks[0]).first else {
            throw IntegrationError.missingFixture("version response frame")
        }

        var payload = frame.payload
        payload = Self.replacing(Array("NWP-F151".utf8), with: Array("SENTINEL".utf8), in: payload)
        payload = Self.replacing(
            Array("Neosmartpen_A1".utf8),
            with: Array("SENTINEL_SUB_1".utf8),
            in: payload
        )

        guard
            let encoded = PenFrameEncoder.encode(
                command: .responseVersionInfo,
                payload: payload,
                errorCode: frame.errorCode ?? 0
            )
        else {
            throw IntegrationError.missingFixture("version response could not be re-encoded")
        }
        chunks[0] = encoded
        return chunks
    }

    /// Replaces every occurrence of one byte sequence with another of equal length.
    private static func replacing(_ needle: [UInt8], with replacement: [UInt8], in bytes: [UInt8]) -> [UInt8] {
        precondition(needle.count == replacement.count, "the sentinel must not change the payload length")
        guard !needle.isEmpty, bytes.count >= needle.count else { return bytes }

        var result = bytes
        var index = 0
        while index <= result.count - needle.count {
            if Array(result[index..<(index + needle.count)]) == needle {
                result.replaceSubrange(index..<(index + needle.count), with: replacement)
                index += needle.count
            } else {
                index += 1
            }
        }
        return result
    }
}

/// A failure the integration harness scripts into a transport.
enum IntegrationTestError: Error, Hashable, Sendable {
    case connectionDropped
}
