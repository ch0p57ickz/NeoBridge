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
