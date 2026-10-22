import Foundation
import NeoCore
import XCTest

@testable import NeoExport

/// Tests for reading an existing version-1 JSON record and for the comparison
/// that decides whether its bytes have to be kept.
final class ExistingJSONPageTests: XCTestCase {
    private let page = PageIdentity(section: 3, owner: 27, book: 700, page: 1)

    // MARK: - Helpers

    private func stroke(
        x: Int32,
        y: Int32 = 0,
        offset: Int64 = 0,
        pressure: UInt16 = 5,
        origin: PenOriginTime = .reliable(milliseconds: 1_700_000_000_000),
        page: PageIdentity? = nil
    ) -> Stroke {
        Stroke(
            page: page ?? self.page,
            originTime: origin,
            points: [
                PenPoint(x: x, y: y, penTimeOffsetMilliseconds: offset, pressure: pressure)
            ],
            source: .offline
        )
    }

    private func document(
        _ strokes: [Stroke],
        page: PageIdentity? = nil
    ) -> PageExportDocument {
        PageExportDocument(page: page ?? self.page, strokes: strokes)
    }

    private func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    private func text(of document: PageExportDocument) -> String {
        String(decoding: JSONPageRenderer.render(document), as: UTF8.self)
    }

    /// The renderer's own bytes for one stroke, which every corruption test edits.
    private func validJSON() -> String {
        text(of: document([stroke(x: 10)]))
    }

    /// Applies one textual change, refusing a change that matches nothing so a
    /// test cannot pass by editing a document it did not touch.
    private func replacing(_ valid: String, _ target: String, with replacement: String) -> String {
        XCTAssertTrue(valid.contains(target), "the document does not contain \(target)")
        return valid.replacingOccurrences(of: target, with: replacement)
    }

    /// A compact record built from explicit stroke text.
    ///
    /// It puts the members in an order the renderer never produces and writes
    /// them without the renderer's whitespace, so a test can separate what a
    /// record says from how it is laid out.
    private func compactJSON(
        _ strokeBlocks: [String],
        page: PageIdentity? = nil,
        formatVersion: String = "1"
    ) -> String {
        let identity = page ?? self.page
        return "{\"strokes\":[\(strokeBlocks.joined(separator: ","))],"
            + "\"formatVersion\":\(formatVersion),\"page\":\(identity.page),"
            + "\"book\":\(identity.book),\"owner\":\(identity.owner),"
            + "\"section\":\(identity.section)}"
    }

    /// One stroke object written compactly.
    private func strokeBlock(
        x: Int32,
        y: Int32 = 0,
        offset: Int64 = 0,
        pressure: UInt16 = 5,
        reliable: Bool = true,
        milliseconds: String = "1700000000000"
    ) -> String {
        "{\"points\":[{\"x\":\(x),\"y\":\(y),\"penTimeOffsetMilliseconds\":\(offset),"
            + "\"pressure\":\(pressure)}],\"originTimeMilliseconds\":\(milliseconds),"
            + "\"originTimeReliable\":\(reliable)}"
    }

    // MARK: - Reading a record

    func testARecordRoundTripsThroughTheRenderer() throws {
        let source = document([stroke(x: 10), stroke(x: 20, y: 5)])

        let record = try XCTUnwrap(ExistingJSONPage.read(JSONPageRenderer.render(source)))

        XCTAssertEqual(record.page, page)
        XCTAssertEqual(Set(record.strokes), Set(source.strokes))
        XCTAssertTrue(record.isSupersededBy(source), "a record supersedes itself")
    }

    func testARecordWithAnUnreliableOriginIsReadBack() throws {
        let source = document([stroke(x: 10, origin: .unreliable(reportedMilliseconds: 42))])
        let record = try XCTUnwrap(ExistingJSONPage.read(JSONPageRenderer.render(source)))

        XCTAssertEqual(record.strokes, source.strokes)
    }

    func testARecordWithNoReportedOriginTimeIsReadBack() throws {
        let source = document([stroke(x: 10, origin: .unreliable(reportedMilliseconds: nil))])
        let record = try XCTUnwrap(ExistingJSONPage.read(JSONPageRenderer.render(source)))

        XCTAssertEqual(record.strokes, source.strokes)
        XCTAssertEqual(
            record.strokes.first?.originTime,
            .unreliable(reportedMilliseconds: nil),
            "a null reported time must not be read as a reported zero"
        )
    }

    func testADocumentThatIsNotOneCompleteRecordIsRefused() {
        let valid = validJSON()
        let refused = [
            "",
            "   ",
            "{",
            "{\"formatVersion\": 1}",
            "not json",
            "[]",
            "null",
            "{\"strokes\": []}",
            // The renderer's own bytes with the closing brace removed.
            String(valid.dropLast(3)),
            valid + "text a user appended\n",
            "// a comment\n" + valid,
        ]

        for text in refused {
            XCTAssertNil(ExistingJSONPage.read(bytes(text)), "must be refused: \(text)")
        }
    }

    func testOnlyTheSupportedFormatVersionIsRead() {
        let valid = validJSON()
        let refused = [
            "\"formatVersion\": 0",
            "\"formatVersion\": 2",
            "\"formatVersion\": 1.0",
            "\"formatVersion\": \"1\"",
            "\"formatVersion\": true",
            "\"formatVersion\": 1000000000000000000000",
        ]

        for replacement in refused {
            let text = replacing(valid, "\"formatVersion\": 1", with: replacement)
            XCTAssertNil(ExistingJSONPage.read(bytes(text)), "must be refused: \(replacement)")
        }
    }

    /// Every field that cannot be validated whole, as a change to a valid
    /// document. A missing field, an unknown one, and a repeated one are all
    /// changes here, because each of them makes the record one this build cannot
    /// compare against the new export.
    func testAFieldThisBuildCannotValidateIsRefused() {
        let valid = validJSON()
        let changes: [(target: String, replacement: String)] = [
            // Page fields.
            ("\"formatVersion\": 1,", "\"formatVersion\": 1,\n  \"extra\": 0,"),
            ("\"section\": 3,", "\"section\": 3,\n  \"section\": 3,"),
            ("\"book\": 700,\n", ""),
            ("\"section\": 3", "\"section\": 300"),
            ("\"owner\": 27", "\"owner\": \"27\""),
            ("\"book\": 700", "\"book\": 4294967296"),
            ("\"page\": 1", "\"page\": -1"),
            ("\"page\": 1", "\"page\": null"),
            ("\"strokes\": [", "\"strokes\": {"),

            // Stroke fields.
            ("\"originTimeReliable\": true,", "\"originTimeReliable\": true,\n      \"extra\": 0,"),
            (
                "\"originTimeMilliseconds\": 1700000000000,",
                "\"originTimeMilliseconds\": 1700000000000,\n      \"originTimeMilliseconds\": 1,"
            ),
            ("\"originTimeReliable\": true,\n", ""),
            ("\"originTimeReliable\": true", "\"originTimeReliable\": 1"),
            ("\"originTimeMilliseconds\": 1700000000000", "\"originTimeMilliseconds\": null"),
            ("\"points\": [", "\"points\": 0"),

            // Point fields.
            ("\"pressure\": 5 }", "\"pressure\": 5, \"extra\": 0 }"),
            ("\"x\": 10, ", "\"x\": 10, \"x\": 11, "),
            (", \"pressure\": 5 }", " }"),
            ("\"pressure\": 5", "\"pressure\": 70000"),
            ("\"pressure\": 5", "\"pressure\": -1"),
            ("\"x\": 10", "\"x\": 10.5"),
            ("\"penTimeOffsetMilliseconds\": 0", "\"penTimeOffsetMilliseconds\": 0.5"),
            ("\"y\": 0", "\"y\": 4294967296"),
        ]

        for change in changes {
            let text = replacing(valid, change.target, with: change.replacement)
            XCTAssertNil(
                ExistingJSONPage.read(bytes(text)),
                "must be refused after replacing \(change.target)"
            )
        }
    }

    func testAnEmptyStrokeListIsAValidRecord() throws {
        let record = try XCTUnwrap(ExistingJSONPage.read(bytes(compactJSON([]))))

        XCTAssertEqual(record.page, page)
        XCTAssertEqual(record.strokes, [])
        XCTAssertTrue(record.isSupersededBy(document([])))
        XCTAssertTrue(
            record.isSupersededBy(document([stroke(x: 10)])),
            "a record with no stroke loses nothing when the library holds one"
        )
    }

    func testAStrokeWithNoPointsIsAValidRecord() throws {
        let block = "{\"points\":[],\"originTimeMilliseconds\":7,\"originTimeReliable\":true}"
        let record = try XCTUnwrap(ExistingJSONPage.read(bytes(compactJSON([block]))))

        XCTAssertEqual(record.strokes.count, 1)
        XCTAssertEqual(record.strokes.first?.points, [])
    }

    // MARK: - Comparing a record with the new export

    func testFormattingAndMemberOrderDoNotMakeAConflict() throws {
        // The same two strokes as the renderer would write, but laid out on one
        // line, with the members in another order and the strokes reversed.
        let existing = compactJSON([strokeBlock(x: 20), strokeBlock(x: 10)])
        let record = try XCTUnwrap(ExistingJSONPage.read(bytes(existing)))

        XCTAssertTrue(
            record.isSupersededBy(document([stroke(x: 10), stroke(x: 20)])),
            "layout, member order, and stroke order change nothing the record says"
        )
    }

    func testAGrowingPageSupersedesTheRecord() throws {
        let record = try XCTUnwrap(ExistingJSONPage.read(bytes(compactJSON([strokeBlock(x: 10)]))))

        XCTAssertTrue(
            record.isSupersededBy(document([stroke(x: 10), stroke(x: 20)])),
            "an added stroke leaves the record's own data in place"
        )
    }

    func testARecordWithAStrokeTheExportLostIsNotSuperseded() throws {
        let existing = compactJSON([strokeBlock(x: 10), strokeBlock(x: 20)])
        let record = try XCTUnwrap(ExistingJSONPage.read(bytes(existing)))

        XCTAssertFalse(
            record.isSupersededBy(document([stroke(x: 10)])),
            "the lost stroke is data the library no longer has"
        )
    }

    func testAReplacedStrokeContentIsNotSuperseded() throws {
        let record = try XCTUnwrap(ExistingJSONPage.read(bytes(compactJSON([strokeBlock(x: 10)]))))

        XCTAssertFalse(record.isSupersededBy(document([stroke(x: 10, y: 1)])))
        XCTAssertFalse(record.isSupersededBy(document([stroke(x: 10, offset: 1)])))
        XCTAssertFalse(record.isSupersededBy(document([stroke(x: 10, pressure: 6)])))
        XCTAssertFalse(
            record.isSupersededBy(
                document([stroke(x: 10, origin: .reliable(milliseconds: 1_700_000_000_001))])
            )
        )
        XCTAssertFalse(
            record.isSupersededBy(
                document([stroke(x: 10, origin: .unreliable(reportedMilliseconds: 1_700_000_000_000))])
            ),
            "an unreliable origin is a different stroke from a reliable one"
        )
    }

    /// A record whose stroke reports no origin time against a library stroke the
    /// pen reported as zero.
    ///
    /// The two files say different things, so the record is not redundant. The
    /// canonical stroke encoding stores an absent reported time as zero, so a
    /// comparison keyed on it alone would treat the two as the same stroke and
    /// replace the file's version without keeping a copy.
    func testAnUnreportedOriginTimeIsNotAReportedZero() throws {
        let absent = try XCTUnwrap(
            ExistingJSONPage.read(
                bytes(compactJSON([strokeBlock(x: 10, reliable: false, milliseconds: "null")]))
            )
        )
        let zero = try XCTUnwrap(
            ExistingJSONPage.read(
                bytes(compactJSON([strokeBlock(x: 10, reliable: false, milliseconds: "0")]))
            )
        )

        XCTAssertEqual(
            absent.strokes.first?.originTime,
            .unreliable(reportedMilliseconds: nil),
            "the record must keep an absent reported time apart from a zero"
        )
        XCTAssertEqual(zero.strokes.first?.originTime, .unreliable(reportedMilliseconds: 0))

        XCTAssertFalse(
            absent.isSupersededBy(
                document([stroke(x: 10, origin: .unreliable(reportedMilliseconds: 0))])
            ),
            "a record that reports no time is not a record that reports zero"
        )
        XCTAssertFalse(
            zero.isSupersededBy(
                document([stroke(x: 10, origin: .unreliable(reportedMilliseconds: nil))])
            ),
            "and the reverse: a reported zero is not an absent time"
        )
        XCTAssertTrue(
            absent.isSupersededBy(
                document([stroke(x: 10, origin: .unreliable(reportedMilliseconds: nil))])
            )
        )
        XCTAssertTrue(
            zero.isSupersededBy(
                document([stroke(x: 10, origin: .unreliable(reportedMilliseconds: 0))])
            )
        )
        XCTAssertFalse(
            absent.isSupersededBy(
                document([stroke(x: 10, origin: .reliable(milliseconds: 0))])
            ),
            "a reported zero the pen does not vouch for is not a trusted zero"
        )
    }

    func testALostDuplicateOccurrenceIsNotSuperseded() throws {
        // Two independent strokes with identical canonical content: the library
        // retained both, so the new export must still carry both.
        let existing = compactJSON([strokeBlock(x: 10), strokeBlock(x: 10)])
        let record = try XCTUnwrap(ExistingJSONPage.read(bytes(existing)))

        XCTAssertEqual(record.strokes.count, 2, "both occurrences must survive the read")
        XCTAssertTrue(record.isSupersededBy(document([stroke(x: 10), stroke(x: 10)])))
        XCTAssertFalse(
            record.isSupersededBy(document([stroke(x: 10)])),
            "losing one of two identical occurrences is still a loss"
        )
    }

    func testARecordOfAnotherPageIsNotSuperseded() throws {
        let otherPage = PageIdentity(section: 3, owner: 27, book: 700, page: 2)
        let existing = compactJSON([strokeBlock(x: 10)], page: otherPage)
        let record = try XCTUnwrap(ExistingJSONPage.read(bytes(existing)))

        XCTAssertEqual(record.page, otherPage)
        XCTAssertFalse(
            record.isSupersededBy(document([stroke(x: 10)])),
            "a record of another page is never this page's data"
        )
    }
}
