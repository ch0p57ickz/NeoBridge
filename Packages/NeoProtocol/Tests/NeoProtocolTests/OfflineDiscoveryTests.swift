import Foundation
import XCTest

@testable import NeoProtocol

final class OfflineDiscoveryTests: XCTestCase {
    // The note the physical A1 capture read.
    private let capturedNote = PenOfflineNote(section: 3, owner: 27, note: 700)

    private func fixture(_ id: String) throws -> ProtocolFixture {
        try FixtureSupport.fixture(id, in: FixtureSupport.all())
    }

    private func payload(_ id: String) throws -> [UInt8] {
        try XCTUnwrap(FixtureSupport.frames(try fixture(id)).first?.payload)
    }

    // MARK: - Note list

    func testNoteListDecodesEachDiscoveredNote() throws {
        guard case .notes(let notes) = PenOfflineListDecoder.decodeNoteList(
            payload: try payload("a1-offline-note-list")
        ) else {
            return XCTFail("expected the note list to decode")
        }

        XCTAssertEqual(
            notes,
            [capturedNote, PenOfflineNote(section: 3, owner: 27, note: 701)]
        )
        // The packed identifier is what a 0x22 or 0x23 request carries.
        XCTAssertEqual(notes.first?.sectionOwnerId, (3 << 24) | 27)
    }

    func testNoteListDecodesTheSectionAndOwnerPacking() throws {
        guard case .notes(let notes) = PenOfflineListDecoder.decodeNoteList(
            payload: try payload("a1-offline-note-list")
        ) else {
            return XCTFail("expected the note list to decode")
        }
        let note = try XCTUnwrap(notes.first)
        XCTAssertEqual(note.section, 3)
        XCTAssertEqual(note.owner, 27)
        XCTAssertEqual(PenWire.sectionAndOwner(note.sectionOwnerId).section, 3)
        XCTAssertEqual(PenWire.sectionAndOwner(note.sectionOwnerId).owner, 27)
    }

    func testEmptyNoteListDecodesToNoNotes() throws {
        guard case .notes(let notes) = PenOfflineListDecoder.decodeNoteList(
            payload: try payload("a1-offline-note-list-empty")
        ) else {
            return XCTFail("expected the empty list to decode")
        }
        XCTAssertTrue(notes.isEmpty)
    }

    func testNoteListWhoseCountExceedsItsEntriesIsMalformed() throws {
        guard case .error(.malformedPayload(let command, let reason)) =
            PenOfflineListDecoder.decodeNoteList(payload: try payload("a1-offline-note-list-malformed"))
        else {
            return XCTFail("expected a malformed note list")
        }
        XCTAssertEqual(command, .responseOfflineNoteList)
        XCTAssertTrue(reason.contains("declares 2 notes"), reason)
    }

    func testNoteListShorterThanItsCountIsMalformed() {
        guard case .error(.malformedPayload(_, let reason)) =
            PenOfflineListDecoder.decodeNoteList(payload: [0x02])
        else {
            return XCTFail("expected a malformed note list")
        }
        XCTAssertTrue(reason.contains("shorter than its count"), reason)
    }

    func testNoteListWithAnEmptyPayloadIsMalformed() {
        guard case .error = PenOfflineListDecoder.decodeNoteList(payload: []) else {
            return XCTFail("expected a malformed note list")
        }
    }

    // MARK: - Page list

    func testPageListDecodesTheDiscoveredPages() throws {
        guard case .pages(let list) = PenOfflineListDecoder.decodePageList(
            payload: try payload("a1-offline-page-list")
        ) else {
            return XCTFail("expected the page list to decode")
        }
        XCTAssertEqual(list.note, capturedNote)
        XCTAssertEqual(list.pages, [1, 16])
    }

    func testPageListWhoseCountExceedsItsEntriesIsMalformed() {
        var payload: [UInt8] = []
        payload.append(contentsOf: PenWire.bytes(UInt32(3) << 24 | 27))
        payload.append(contentsOf: PenWire.bytes(UInt32(700)))
        payload.append(contentsOf: PenWire.bytes(UInt16(3)))
        payload.append(contentsOf: PenWire.bytes(UInt32(1)))

        guard case .error(.malformedPayload(let command, let reason)) =
            PenOfflineListDecoder.decodePageList(payload: payload)
        else {
            return XCTFail("expected a malformed page list")
        }
        XCTAssertEqual(command, .responseOfflinePageList)
        XCTAssertTrue(reason.contains("declares 3 pages"), reason)
    }

    func testPageListShorterThanItsHeaderIsMalformed() {
        guard case .error(.malformedPayload(_, let reason)) =
            PenOfflineListDecoder.decodePageList(payload: [0, 0, 0, 0])
        else {
            return XCTFail("expected a malformed page list")
        }
        XCTAssertTrue(reason.contains("shorter than its header"), reason)
    }

    // MARK: - Offline data info

    func testOfflineDataInfoDecodesTheSummary() throws {
        let info = try XCTUnwrap(
            PenOfflineListDecoder.decodeInfo(payload: try payload("a1-offline-data-info"))
        )
        // The values the physical A1 reported while its stream carried two more
        // stroke records, which is why the summary is diagnostics only.
        XCTAssertEqual(info.strokeCount, 6_918)
        XCTAssertEqual(info.uncompressedSize, 1_309_538)
        XCTAssertFalse(info.isCompressed)
    }

    func testOfflineDataInfoShorterThanItsLayoutIsRejected() {
        XCTAssertNil(PenOfflineListDecoder.decodeInfo(payload: [0, 0, 0, 0]))
    }

    // MARK: - Request layouts

    func testNoteListRequestCarriesTheDocumentedWildcard() throws {
        let frame = try XCTUnwrap(PenRequest.noteList())
        XCTAssertEqual(FixtureSupport.outboundCommands([frame]), [.offlineNoteListRequest])
        XCTAssertEqual(
            frame,
            PenFrameEncoder.encode(
                command: .offlineNoteListRequest,
                payload: [0xFF, 0xFF, 0xFF, 0xFF]
            )
        )
        XCTAssertEqual(PenRequest.noteListSectionOwnerWildcard, 0xFFFF_FFFF)
    }

    func testPageListRequestCarriesTheDiscoveredIdentifiers() throws {
        let frame = try XCTUnwrap(PenRequest.pageList(for: capturedNote))
        // sectionOwnerId (4) then note id (4), little-endian.
        let expectedPayload: [UInt8] = [0x1B, 0x00, 0x00, 0x03, 0xBC, 0x02, 0x00, 0x00]
        XCTAssertEqual(
            frame,
            PenFrameEncoder.encode(command: .offlinePageListRequest, payload: expectedPayload)
        )
    }

    func testOfflineDataRequestUsesTheTracedOptionsAndZeroPageCount() throws {
        let frame = try XCTUnwrap(PenRequest.offlineData(for: capturedNote))
        // next-and-reserve (2), no compression (0), sectionOwnerId, note id,
        // and a page count of zero.
        let expectedPayload: [UInt8] = [
            0x02, 0x00,
            0x1B, 0x00, 0x00, 0x03,
            0xBC, 0x02, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00
        ]
        XCTAssertEqual(
            frame,
            PenFrameEncoder.encode(command: .offlineDataRequest1, payload: expectedPayload)
        )
    }

    func testOfflineDataRequestCarriesAnExplicitPageList() throws {
        let frame = try XCTUnwrap(
            PenRequest.offlineData(
                sectionOwnerId: capturedNote.sectionOwnerId,
                noteId: capturedNote.note,
                transferOption: .notNextTransfer,
                compressionOption: .none,
                pageCount: 2,
                pages: [1, 16]
            )
        )
        // The payload grows by four bytes per requested page.
        XCTAssertEqual(frame.count, try XCTUnwrap(PenRequest.offlineData(for: capturedNote)).count + 8)
    }

    func testAcknowledgementCarriesThePacketIdentifierAndOperation() throws {
        let frame = try XCTUnwrap(
            PenRequest.acknowledgement(packetID: 0x0102, operation: .stop)
        )
        // A response frame: command, error code, length, then the body.
        let expected: [UInt8] = [
            PenFraming.start,
            PenCommand.responseOfflineData.rawValue,
            0x00,
            0x03, 0x00,
            0x02, 0x01,
            PenTransferAcknowledgement.stop.rawValue,
            PenFraming.end
        ]
        XCTAssertEqual(frame, expected)
        XCTAssertEqual(PenTransferAcknowledgement.next.rawValue, 1)
    }

    func testVersionRequestMatchesTheCapturedExchange() throws {
        let frame = try XCTUnwrap(PenRequest.versionInfo())
        let capture = try FixtureSupport.fixture("a1-handshake-version-2.23", in: FixtureSupport.all())
        XCTAssertEqual(frame, try XCTUnwrap(capture.decodedChunks().first))

        // The body is the SDK layout: connection code (16), app type (2),
        // application version (16), declared protocol version (8). On the wire
        // that is the start marker, the command, the length, the 42-byte body,
        // and the end marker.
        XCTAssertEqual(frame.count, 3 + 42 + 2)
        XCTAssertEqual(PenRequest.sdkAppType, 0x1211)
        XCTAssertEqual(PenRequest.sdkDeclaredProtocolVersion, "2.18")
        XCTAssertEqual(PenRequest.defaultConnectionCode, [UInt8](repeating: 0, count: 16))
    }

    func testOverlongTextFieldsAreTruncatedToTheirWidth() throws {
        let frame = try XCTUnwrap(
            PenRequest.versionInfo(
                connectionCode: [UInt8](repeating: 0xAA, count: 40),
                appVersion: "a-very-long-application-version",
                protocolVersion: "2.18"
            )
        )
        // The fixed layout still holds: a request body is always 42 bytes.
        XCTAssertEqual(frame.count, 3 + 42 + 2)
    }
}
