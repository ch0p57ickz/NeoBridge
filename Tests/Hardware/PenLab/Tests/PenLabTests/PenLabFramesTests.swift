import XCTest

@testable import PenLab

/// Pins the framing the deletion experiment sends and reads.
///
/// The two request frames are asserted byte for byte against what the physical A1 was
/// sent and answered, which is also the layout Neo iOS SDK 3.0 documents
/// (`NISDK3/Classes/Model/RequestStruct.swift`). No app target can build them:
/// `PenCommand.frameKind` returns `nil` for `0x25` and `0x27`, so a change to the layout
/// in `PenLabFrames` must fail here.
final class PenLabFramesTests: XCTestCase {
    /// Bytes from a hexadecimal string, for a test's inbound run.
    private func bytes(_ hex: String) -> [UInt8] {
        var values: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            values.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
            index = next
        }
        return values
    }

    // MARK: - Requests

    func testDeleteNoteRequestMatchesTheFrameThePenAccepted() {
        let frame = PenLabFrames.deleteNoteRequest(section: 3, owner: 27, notes: [700])

        XCTAssertEqual(
            PenLabFrames.hex(frame),
            "C02509001B00000301BC020000C1",
            "the 0x25 frame must keep the layout the A1 accepted: command, length 9, "
                + "packed section and owner, a count, then little-endian note identifiers"
        )
    }

    func testDeletePageRequestMatchesTheFrameThePenRefused() {
        let frame = PenLabFrames.deletePageRequest(section: 3, owner: 27, note: 700, pages: [1])

        XCTAssertEqual(
            PenLabFrames.hex(frame),
            "C0270D001B000003BC0200000101000000C1",
            "the 0x27 frame must keep the layout the SDK documents: command, length 13, "
                + "packed section and owner, the note, a count, then little-endian page identifiers"
        )
    }

    func testDeleteNoteRequestCarriesEveryNoteAndItsCount() {
        let frame = PenLabFrames.deleteNoteRequest(section: 1, owner: 2, notes: [700, 701])

        XCTAssertEqual(
            PenLabFrames.hex(frame),
            "C0250D000200000102BC020000BD020000C1",
            "length is 5 plus four bytes per note, and both identifiers travel"
        )
    }

    func testSectionOwnerIdPacksTheSectionIntoTheTopByte() {
        XCTAssertEqual(PenLabFrames.sectionOwnerId(section: 3, owner: 27), 0x0300_001B)
        XCTAssertEqual(
            PenLabFrames.littleEndian32(PenLabFrames.sectionOwnerId(section: 3, owner: 27)),
            [0x1B, 0x00, 0x00, 0x03]
        )
    }

    // MARK: - Escaping

    func testFrameEscapesTheMarkersAndTheEscapeByte() {
        let frame = PenLabFrames.framed([0xC0, 0xC1, 0x7D, 0x00])

        XCTAssertEqual(
            PenLabFrames.hex(frame),
            "C07DE07DE17D5D00C1",
            "a body byte that is a marker or the escape byte travels as 0x7D and the byte with 0x20 toggled"
        )
    }

    // MARK: - Reading

    func testExtractSplitsEveryCompleteFrameAndDropsWhatSurroundsThem() {
        let frames = PenLabFrames.extract(from: bytes("00FFC081000100ABC1C0A5000200ABCDC1"))

        XCTAssertEqual(frames.map(\.command), [0x81, 0xA5])
        XCTAssertEqual(frames[0].errorCode, 0x00)
        XCTAssertEqual(frames[0].payload, [0xAB])
        XCTAssertEqual(frames[1].payload, [0xAB, 0xCD])
    }

    func testExtractUnescapesTheBody() {
        let frames = PenLabFrames.extract(from: bytes("C0A50001007DE0C1"))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, [0xC0], "an escaped 0xE0 is the marker byte 0xC0")
    }

    func testExtractKeepsAnIncompleteFrameOutOfTheResult() {
        let frames = PenLabFrames.extract(from: bytes("C0A5000100"))

        XCTAssertTrue(frames.isEmpty, "a frame without its closing marker is not an answer")
    }

    // MARK: - Responses

    func testResponseFrameSplitsTheErrorCodeAndTheDeclaredLength() {
        let frame = PenLabFrames.frame(from: [0xA5, 0x00, 0x01, 0x00, 0x01])

        XCTAssertEqual(frame?.command, 0xA5)
        XCTAssertEqual(frame?.errorCode, 0x00)
        XCTAssertEqual(frame?.declaredLength, 1)
        XCTAssertEqual(frame?.payload, [0x01])
        XCTAssertEqual(frame?.isTruncated, false)
        XCTAssertEqual(frame?.framingIsFromEvidence, true, "0xA5 is a response in the evidence table")
        XCTAssertEqual(frame?.bodyHex, "A500010001")
    }

    func testRefusedResponseKeepsItsErrorCodeAndEmptyPayload() {
        let frame = PenLabFrames.frame(from: [0xA7, 0x05, 0x00, 0x00])

        XCTAssertEqual(frame?.errorCode, 0x05)
        XCTAssertEqual(frame?.declaredLength, 0)
        XCTAssertEqual(frame?.payload, [])
        XCTAssertEqual(frame?.isTruncated, false)
    }

    func testAFrameShorterThanItsDeclaredLengthIsReportedAsTruncated() {
        let frame = PenLabFrames.frame(from: [0xA5, 0x00, 0x05, 0x00, 0x01])

        XCTAssertEqual(frame?.declaredLength, 5)
        XCTAssertEqual(frame?.payload, [0x01], "the payload stops at the bytes that arrived")
        XCTAssertEqual(frame?.isTruncated, true, "a short body is not a complete answer")
    }

    func testTheBodyIsKeptWholeSoATrailingMisreadingIsVisible() {
        // A body whose declared length is shorter than the bytes that followed it. The
        // transcript has to be able to show this, because reading the payload alone
        // would silently drop the difference.
        let frame = PenLabFrames.frame(from: [0xA5, 0x00, 0x01, 0x00, 0x01, 0xBC, 0x02, 0x00, 0x00])

        XCTAssertEqual(frame?.declaredLength, 1)
        XCTAssertEqual(frame?.payload, [0x01])
        XCTAssertEqual(frame?.bodyHex, "A500010001BC020000")
    }

    func testUnclassifiedCommandKeepsItsBytesWhole() {
        let frame = PenLabFrames.frame(from: [0x99, 0x01, 0x02])

        XCTAssertEqual(frame?.framingIsFromEvidence, false)
        XCTAssertNil(frame?.declaredLength, "an unclassified identifier has no known length position")
        XCTAssertEqual(frame?.payload, [0x01, 0x02])
        XCTAssertEqual(frame?.isTruncated, false)
    }

    // MARK: - The identifiers a deletion answer names

    func testDeletedIdentifiersReadsACountAndThatManyIdentifiers() {
        let payload: [UInt8] = [0x02, 0xBC, 0x02, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00]

        XCTAssertEqual(PenLabFrames.deletedIdentifiers(in: payload), [700, 10])
    }

    func testDeletedIdentifiersAcceptsACountOfZero() {
        XCTAssertEqual(PenLabFrames.deletedIdentifiers(in: [0x00]), [])
    }

    func testDeletedIdentifiersRefusesACountWithNoIdentifiersBehindIt() {
        XCTAssertNil(
            PenLabFrames.deletedIdentifiers(in: [0x01]),
            "a count of one with no identifier bytes is not a complete list"
        )
    }

    func testDeletedIdentifiersRefusesATrailingByte() {
        XCTAssertNil(
            PenLabFrames.deletedIdentifiers(in: [0x01, 0xBC, 0x02, 0x00, 0x00, 0xFF]),
            "a payload longer than the count implies is not read as a shorter list"
        )
    }
}
