import Foundation
import NeoCore
import XCTest

@testable import NeoExport

/// Golden and determinism tests for the three renderers.
final class PageExportGoldenTests: XCTestCase {
    private let page = PageIdentity(section: 3, owner: 27, book: 700, page: 1)

    private func point(x: Int32, y: Int32, offset: Int64 = 0, pressure: UInt16 = 12) -> PenPoint {
        PenPoint(x: x, y: y, penTimeOffsetMilliseconds: offset, pressure: pressure)
    }

    private func stroke(
        origin: PenOriginTime = .reliable(milliseconds: 1_700_000_000_000),
        points: [PenPoint]? = nil,
        source: PenSource = .offline,
        page: PageIdentity? = nil
    ) -> Stroke {
        Stroke(
            page: page ?? self.page,
            originTime: origin,
            points: points ?? [point(x: -12_345, y: 67_890)],
            source: source
        )
    }

    private func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Golden bytes

    func testJSONGoldenBytes() {
        let document = PageExportDocument(page: page, strokes: [stroke()])

        let expected = """
            {
              "formatVersion": 1,
              "section": 3,
              "owner": 27,
              "book": 700,
              "page": 1,
              "strokes": [
                {
                  "originTimeReliable": true,
                  "originTimeMilliseconds": 1700000000000,
                  "points": [
                    { "x": -12345, "y": 67890, "penTimeOffsetMilliseconds": 0, "pressure": 12 }
                  ]
                }
              ]
            }

            """

        XCTAssertEqual(text(JSONPageRenderer.render(document)), expected)
    }

    func testSVGGoldenBytes() {
        let document = PageExportDocument(
            page: page,
            strokes: [stroke(points: [point(x: 3_301, y: 752), point(x: 3_305, y: 827)])]
        )

        let expected = """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" version="1.1" viewBox="0 0 54.84 88.58" width="130.0mm" height="210.0mm">
              <title>Ncode page section 3, owner 27, book 700, page 1</title>
              <desc>1 stroke(s), 2 dot(s)</desc>
              <g fill="none" stroke="#000000" stroke-width="0.15" stroke-linecap="round" stroke-linejoin="round">
                <path d="M 33.01,7.52 L 33.05,8.27"/>
              </g>
            </svg>

            """

        XCTAssertEqual(text(SVGPageRenderer.render(document)), expected)
    }

    func testMarkdownGoldenBytes() {
        let document = PageExportDocument(page: page, strokes: [stroke()])

        let expected = """
            # Ncode page section 3, owner 27, book 700, page 1

            | Field | Value |
            | --- | --- |
            | Section | 3 |
            | Owner | 27 |
            | Book | 700 |
            | Page | 1 |
            | Format version | 1 |
            | Strokes | 1 |
            | Dots | 1 |

            ## Files

            - [JSON](ncode-s3-o27-b700-p1.json)
            - [SVG](ncode-s3-o27-b700-p1.svg)

            """

        XCTAssertEqual(text(MarkdownPageRenderer.render(document)), expected)
    }

    func testFilesUseUnixNewlinesAndEndWithOne() {
        let document = PageExportDocument(page: page, strokes: [stroke()])

        for format in PenExportFormat.allCases {
            let bytes = FilePenExportPublisher.render(document, format: format)
            let rendered = text(bytes)
            XCTAssertFalse(rendered.contains("\r"), "\(format) must not use CRLF")
            XCTAssertTrue(rendered.hasSuffix("\n"), "\(format) must end with a newline")
            XCTAssertFalse(rendered.hasSuffix("\n\n\n"), "\(format) must not end with blank lines")
        }
    }

    // MARK: - Determinism

    func testReorderedStrokesRenderIdenticalBytes() {
        let first = stroke(points: [point(x: 10, y: 10)])
        let second = stroke(points: [point(x: 20, y: 20)])
        let third = stroke(
            origin: .reliable(milliseconds: 1_600_000_000_000),
            points: [point(x: 30, y: 30)]
        )

        let forward = PageExportDocument(page: page, strokes: [first, second, third])
        let reversed = PageExportDocument(page: page, strokes: [third, second, first])

        for format in PenExportFormat.allCases {
            XCTAssertEqual(
                FilePenExportPublisher.render(forward, format: format),
                FilePenExportPublisher.render(reversed, format: format),
                "\(format) must not depend on import order"
            )
        }
    }

    func testLiveAndOfflineCopiesRenderIdenticalBytes() {
        let offline = PageExportDocument(page: page, strokes: [stroke(source: .offline)])
        let live = PageExportDocument(page: page, strokes: [stroke(source: .live)])

        for format in PenExportFormat.allCases {
            XCTAssertEqual(
                FilePenExportPublisher.render(offline, format: format),
                FilePenExportPublisher.render(live, format: format),
                "\(format) must not depend on the source"
            )
        }
    }

    func testASeparatelyBuiltDocumentRendersTheSameBytes() {
        // A second process would build the document from the same rows, so the
        // bytes must not depend on anything the process carried.
        let first = PageExportDocument(page: page, strokes: [stroke()])
        let second = PageExportDocument(page: page, strokes: [stroke()])

        for format in PenExportFormat.allCases {
            XCTAssertEqual(
                FilePenExportPublisher.render(first, format: format),
                FilePenExportPublisher.render(second, format: format)
            )
        }
    }

    func testIdenticalUnreliableStrokesKeepTheirMultiplicity() {
        let unreliable = stroke(
            origin: .unreliable(reportedMilliseconds: nil),
            points: [point(x: 1, y: 2)]
        )

        let document = PageExportDocument(page: page, strokes: [unreliable, unreliable, unreliable])
        XCTAssertEqual(document.strokes.count, 3)

        let rendered = text(JSONPageRenderer.render(document))
        let occurrences = rendered.components(separatedBy: "\"originTimeReliable\": false").count - 1
        XCTAssertEqual(occurrences, 3, "every retained occurrence must appear in the exported data")
        XCTAssertTrue(rendered.contains("\"originTimeMilliseconds\": null"))
    }

    func testAnUnreliableStrokeWithAReportedTimeKeepsThatTime() {
        let document = PageExportDocument(
            page: page,
            strokes: [stroke(origin: .unreliable(reportedMilliseconds: 42))]
        )

        let rendered = text(JSONPageRenderer.render(document))
        XCTAssertTrue(rendered.contains("\"originTimeReliable\": false"))
        XCTAssertTrue(rendered.contains("\"originTimeMilliseconds\": 42"))
    }

    // MARK: - Empty pages

    func testAnEmptyPageRendersNoFiles() async throws {
        let directory = try TemporaryExportDirectory()
        defer { directory.remove() }

        let publisher = FilePenExportPublisher()
        let report = await publisher.publish(
            PenExportRequest(pages: [page], destinationDirectory: directory.url.path),
            content: [PenPageContent(page: page, strokes: [])]
        )

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(try directory.entries(), [])
    }

    func testARequestedPageWithNoContentRendersNoFiles() async throws {
        let directory = try TemporaryExportDirectory()
        defer { directory.remove() }

        let publisher = FilePenExportPublisher()
        let report = await publisher.publish(
            PenExportRequest(pages: [page], destinationDirectory: directory.url.path),
            content: []
        )

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(try directory.entries(), [])
    }

    // MARK: - File names and identity

    func testPagesThatShareAPageNumberDoNotCollide() async throws {
        let directory = try TemporaryExportDirectory()
        defer { directory.remove() }

        let otherBook = PageIdentity(section: 3, owner: 27, book: 701, page: 1)
        let otherOwner = PageIdentity(section: 3, owner: 28, book: 700, page: 1)
        let otherSection = PageIdentity(section: 4, owner: 27, book: 700, page: 1)

        let publisher = FilePenExportPublisher()
        let report = await publisher.publish(
            PenExportRequest(
                pages: [page, otherBook, otherOwner, otherSection],
                destinationDirectory: directory.url.path
            ),
            content: [page, otherBook, otherOwner, otherSection].map {
                PenPageContent(page: $0, strokes: [stroke(page: $0)])
            }
        )

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.artifacts.count, 12)

        let names = Set(report.artifacts.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        XCTAssertEqual(names.count, 12, "every page and format needs its own path")

        for page in [page, otherBook, otherOwner, otherSection] {
            let json = directory.url.appendingPathComponent("ncode-s\(page.section)-o\(page.owner)-b\(page.book)-p\(page.page).json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
            let content = try String(contentsOf: json, encoding: .utf8)
            XCTAssertTrue(content.contains("\"section\": \(page.section)"))
            XCTAssertTrue(content.contains("\"owner\": \(page.owner)"))
            XCTAssertTrue(content.contains("\"book\": \(page.book)"))
            XCTAssertTrue(content.contains("\"page\": \(page.page)"))
        }
    }

    // MARK: - Escaping and secrets

    func testXMLEscapingCoversEveryMarkupCharacter() {
        XCTAssertEqual(
            ExportEscaping.xml("a & b < c > d \" e ' f"),
            "a &amp; b &lt; c &gt; d &quot; e &apos; f"
        )
    }

    func testMarkdownEscapingNeutralisesMarkup() {
        XCTAssertEqual(
            ExportEscaping.markdown("[link](target) *bold* `code` # heading"),
            "\\[link\\]\\(target\\) \\*bold\\* \\`code\\` \\# heading"
        )
    }

    func testEscapedTextNeverLeaksTheRawValue() {
        let hostile = "<script>alert('x')</script> & [x](y)"
        XCTAssertFalse(ExportEscaping.xml(hostile).contains("<script>"))
        XCTAssertFalse(ExportEscaping.markdown(hostile).contains("(y)"))
    }

    func testExportedFilesCarryNoDeviceSecrets() {
        // A read's device identifiers, firmware text, and authentication material
        // never reach a renderer: the only inputs are the page tuple and the
        // strokes. This test pins that the words and shapes cannot appear.
        let document = PageExportDocument(page: page, strokes: [stroke()])
        let forbidden = [
            "bluetooth", "address", "serial", "firmware", "password", "passcode",
            "token", "secret", "credential", "connectionCode", "sub-name",
            "Neosmartpen", "source", "offline", "live", "batchID", "strokeID",
        ]

        for format in PenExportFormat.allCases {
            let rendered = text(FilePenExportPublisher.render(document, format: format)).lowercased()
            for word in forbidden {
                XCTAssertFalse(
                    rendered.contains(word.lowercased()),
                    "\(format) must not contain \(word)"
                )
            }
        }
    }

    func testExportCarriesTheNumbersAndOnlyThoseNumbers() {
        let document = PageExportDocument(page: page, strokes: [stroke()])
        let rendered = text(JSONPageRenderer.render(document))

        // Every number in the JSON record is a page component or stroke data.
        let numbers = rendered
            .components(separatedBy: CharacterSet(charactersIn: "-0123456789").inverted)
            .filter { !$0.isEmpty }
        XCTAssertEqual(
            Set(numbers),
            Set(["1", "3", "27", "700", "1700000000000", "-12345", "67890", "0", "12"])
        )
    }

    // MARK: - Page canvas

    func testEveryPageRendersOnTheSameCanvas() {
        // The canvas is the sheet, not the ink, so two pages of one note share a
        // scale and an origin and can be compared or overlaid. Deriving it from
        // each page's own ink is what made every page a different size.
        let sparse = PageExportDocument(
            page: page,
            strokes: [stroke(points: [point(x: 3_301, y: 752)])]
        )
        let dense = PageExportDocument(
            page: PageIdentity(section: 3, owner: 27, book: 700, page: 23),
            strokes: [stroke(points: [point(x: 552, y: 906), point(x: 4_965, y: 8_036)])]
        )

        let sparseSVG = text(SVGPageRenderer.render(sparse))
        let denseSVG = text(SVGPageRenderer.render(dense))

        XCTAssertTrue(
            sparseSVG.contains("viewBox=\"0 0 54.84 88.58\""),
            "the canvas must not shrink to the ink: \(sparseSVG)"
        )
        XCTAssertTrue(denseSVG.contains("viewBox=\"0 0 54.84 88.58\""))
        XCTAssertTrue(sparseSVG.contains("width=\"130.0mm\" height=\"210.0mm\""))
        XCTAssertTrue(denseSVG.contains("width=\"130.0mm\" height=\"210.0mm\""))
    }

    func testTheCanvasGrowsToFitInkPastTheSheet() {
        // Ink past the sheet's right or bottom edge grows the canvas rather than
        // being clipped, and only the size changes: the origin stays at zero so
        // pages of a note still line up.
        let document = PageExportDocument(
            page: page,
            strokes: [stroke(points: [point(x: 6_000, y: 9_000)])]
        )

        let rendered = text(SVGPageRenderer.render(document))
        XCTAssertTrue(
            rendered.contains("viewBox=\"0 0 60.08 90.08\""),
            "the canvas must cover a point past the sheet: \(rendered)"
        )
        XCTAssertTrue(rendered.contains("width=\"142.4mm\" height=\"213.5mm\""))
    }

    func testANegativePointDoesNotMoveTheOrigin() {
        // A real read cannot produce a negative coordinate, because the wire
        // format carries a UInt16 integer part, and PenPoint is built from it. A
        // coordinate read back from the library as Int32 could still be negative,
        // so the origin must not move even then: a canvas that shifted would stop
        // two pages of a note from lining up. The point is left off the canvas
        // instead, which is the documented trade.
        let document = PageExportDocument(
            page: page,
            strokes: [stroke(points: [point(x: -5_000, y: -5_000)])]
        )

        let rendered = text(SVGPageRenderer.render(document))
        XCTAssertTrue(rendered.contains("viewBox=\"0 0 54.84 88.58\""))
    }

    func testACorruptCoordinateSaturatesInsteadOfOverflowing() {
        // A stored coordinate near Int32.max must not trap the renderer.
        let extent = PageCanvas.extent(forPoints: [point(x: Int32.max, y: Int32.max)])
        XCTAssertEqual(extent.width, Int32.max)
        XCTAssertEqual(extent.height, Int32.max)
    }

    func testTheStrokeWidthIsAPenLineAndNotAPenUnit() {
        // One pen unit is 2.37 mm, so a width of one unit drew a line wider than
        // most strokes are long. The SDK's own renderer draws one point.
        XCTAssertEqual(PageCanvas.strokeWidthHundredths, 15)
        XCTAssertEqual(ExportNumberFormat.hundredths(PageCanvas.strokeWidthHundredths), "0.15")

        let document = PageExportDocument(page: page, strokes: [stroke()])
        XCTAssertTrue(text(SVGPageRenderer.render(document)).contains("stroke-width=\"0.15\""))
    }

    func testTheCanvasIsTheDocumentedSheet() {
        XCTAssertEqual(ExportNumberFormat.millimetres(PageCanvas.widthHundredths), "130.0")
        XCTAssertEqual(ExportNumberFormat.millimetres(PageCanvas.heightHundredths), "210.0")
    }

    func testAnEmptySVGPageStillRendersValidMarkup() {
        let document = PageExportDocument(page: page, strokes: [])
        let rendered = text(SVGPageRenderer.render(document))
        XCTAssertTrue(rendered.contains("viewBox=\"0 0 54.84 88.58\""))
        XCTAssertTrue(rendered.contains("0 stroke(s), 0 dot(s)"))
        XCTAssertTrue(rendered.hasSuffix("</svg>\n"))
    }

    // MARK: - Number formatting

    func testHundredthsFormattingIsFixedAndLocaleIndependent() {
        XCTAssertEqual(ExportNumberFormat.hundredths(0), "0.00")
        XCTAssertEqual(ExportNumberFormat.hundredths(5), "0.05")
        XCTAssertEqual(ExportNumberFormat.hundredths(50), "0.50")
        XCTAssertEqual(ExportNumberFormat.hundredths(100), "1.00")
        XCTAssertEqual(ExportNumberFormat.hundredths(-1), "-0.01")
        XCTAssertEqual(ExportNumberFormat.hundredths(-12_345), "-123.45")
        XCTAssertEqual(ExportNumberFormat.hundredths(Int32.max), "21474836.47")
        XCTAssertEqual(ExportNumberFormat.hundredths(Int32.min), "-21474836.48")
    }

    func testMillimetreFormattingIsFixedAndLocaleIndependent() {
        // One pen unit is 889/375 mm, so one unit (100 hundredths) is 2.4 mm and
        // the 130 x 210 mm sheet is 54.84 x 88.58 units.
        XCTAssertEqual(ExportNumberFormat.millimetres(0), "0.0")
        XCTAssertEqual(ExportNumberFormat.millimetres(100), "2.4")
        XCTAssertEqual(ExportNumberFormat.millimetres(1_000), "23.7")
        XCTAssertEqual(ExportNumberFormat.millimetres(-1_000), "-23.7")
        XCTAssertEqual(ExportNumberFormat.millimetres(5_484), "130.0")
        XCTAssertEqual(ExportNumberFormat.millimetres(8_858), "210.0")
        XCTAssertEqual(ExportNumberFormat.millimetres(Int32.max), "50909679.0")
        XCTAssertEqual(ExportNumberFormat.millimetres(Int32.min), "-50909679.0")
    }

    func testMillimetreRoundingTurnsOverAtTheHalfTenth() {
        // Half a tenth of a millimetre is 1875/889 = 2.11 hundredths, so 2
        // hundredths rounds down to 0.0 mm and 3 rounds up to 0.1 mm. Without the
        // rounding term in the formatter, 3 would truncate to 0.0 and this fails.
        XCTAssertEqual(ExportNumberFormat.millimetres(2), "0.0")
        XCTAssertEqual(ExportNumberFormat.millimetres(3), "0.1")
        XCTAssertEqual(ExportNumberFormat.millimetres(-2), "0.0")
        XCTAssertEqual(ExportNumberFormat.millimetres(-3), "-0.1")
    }
}

/// A temporary directory an export test may write to.
struct TemporaryExportDirectory {
    /// The directory.
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoexport-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// The directory's entries, sorted.
    func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    /// Removes the directory and its contents.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
