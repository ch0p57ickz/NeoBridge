import Foundation
import NeoCore
import XCTest

@testable import NeoExport

/// Tests for safe publication: atomic replacement, the format-specific backup
/// rules, symlink refusal, per-file reporting, and retry.
final class FilePublicationTests: XCTestCase {
    private let page = PageIdentity(section: 3, owner: 27, book: 700, page: 1)
    private var directory: TemporaryExportDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryExportDirectory()
    }

    override func tearDown() {
        directory.remove()
        directory = nil
    }

    // MARK: - Helpers

    private func stroke(
        x: Int32,
        origin: PenOriginTime = .reliable(milliseconds: 1_700_000_000_000)
    ) -> Stroke {
        Stroke(
            page: page,
            originTime: origin,
            points: [PenPoint(x: x, y: 0, penTimeOffsetMilliseconds: 0, pressure: 5)],
            source: .offline
        )
    }

    private func request() -> PenExportRequest {
        PenExportRequest(pages: [page], destinationDirectory: directory.url.path)
    }

    private func content(_ strokes: [Stroke]) -> [PenPageContent] {
        [PenPageContent(page: page, strokes: strokes)]
    }

    private func content(x: Int32) -> [PenPageContent] {
        content([stroke(x: x)])
    }

    private func jsonText(_ strokes: [Stroke]) -> String {
        String(
            decoding: JSONPageRenderer.render(PageExportDocument(page: page, strokes: strokes)),
            as: UTF8.self
        )
    }

    private func backupPath(_ format: PenExportFormat, depth: Int) -> String {
        "\(targetPath(format)).bak\(depth)"
    }

    private func backupExists(_ format: PenExportFormat, depth: Int = 1) -> Bool {
        FileManager.default.fileExists(atPath: backupPath(format, depth: depth))
    }

    private func targetPath(_ format: PenExportFormat) -> String {
        directory.url.appendingPathComponent("ncode-s3-o27-b700-p1.\(format.fileExtension)").path
    }

    private func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    private func entries() throws -> [String] {
        try directory.entries()
    }

    // MARK: - Publication

    func testEveryFormatIsPublishedOnce() async throws {
        let publisher = FilePenExportPublisher()
        let report = await publisher.publish(request(), content: content(x: 10))

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.artifacts.map(\.format), [.json, .svg, .markdown])
        XCTAssertEqual(report.published.count, 3)
        XCTAssertEqual(report.unchanged, [])
        XCTAssertEqual(report.failed, [])

        XCTAssertEqual(
            try entries(),
            [
                "ncode-s3-o27-b700-p1.json",
                "ncode-s3-o27-b700-p1.md",
                "ncode-s3-o27-b700-p1.svg",
            ]
        )
    }

    func testReExportOfUnchangedContentLeavesTheTargetAndCreatesNoBackup() async throws {
        let publisher = FilePenExportPublisher()
        _ = await publisher.publish(request(), content: content(x: 10))
        let before = try read(targetPath(.json))

        let second = await publisher.publish(request(), content: content(x: 10))

        XCTAssertTrue(second.succeeded)
        XCTAssertEqual(second.unchanged.map(\.format), [.json, .svg, .markdown])
        XCTAssertEqual(second.published, [])
        XCTAssertEqual(try read(targetPath(.json)), before)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "\(targetPath(.json)).bak1"),
            "an unchanged target must not create a backup"
        )
    }

    func testADifferingTargetIsPreservedBeforeItIsReplaced() async throws {
        let publisher = FilePenExportPublisher()
        _ = await publisher.publish(request(), content: content(x: 10))

        try write("a user's own notes\n", to: targetPath(.json))
        let report = await publisher.publish(request(), content: content(x: 20))

        XCTAssertTrue(report.succeeded)
        // The JSON and the SVG both carry the coordinate, so both differ; the
        // Markdown carries only counts, so it is left alone.
        XCTAssertEqual(report.published.map(\.format), [.json, .svg])
        XCTAssertEqual(report.unchanged.map(\.format), [.markdown])

        XCTAssertEqual(
            try read("\(targetPath(.json)).bak1"),
            "a user's own notes\n",
            "the prior bytes must stay recoverable"
        )
        let replaced = try read(targetPath(.json))
        XCTAssertTrue(replaced.contains("\"x\": 20"))
    }

    func testBackupHistoryKeepsAtMostThreeVersions() async throws {
        let publisher = FilePenExportPublisher()
        let path = targetPath(.json)

        // Five successive differing versions: version N is written, then edited
        // by hand, then replaced by version N+1.
        for version in 1...5 {
            _ = await publisher.publish(request(), content: content(x: Int32(version)))
            try write("hand edit \(version)\n", to: path)
        }

        XCTAssertEqual(try read("\(path).bak1"), "hand edit 4\n")
        XCTAssertEqual(try read("\(path).bak2"), "hand edit 3\n")
        XCTAssertEqual(try read("\(path).bak3"), "hand edit 2\n")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "\(path).bak4"),
            "the history is bounded at three versions"
        )
    }

    // MARK: - Backups by format

    func testOrdinaryPageGrowthReplacesTheJSONWithoutABackup() async throws {
        let publisher = FilePenExportPublisher()
        _ = await publisher.publish(request(), content: content(x: 10))

        // The library's page grew: the export is the whole page, not the new
        // strokes alone.
        let report = await publisher.publish(
            request(),
            content: content([stroke(x: 10), stroke(x: 20)])
        )

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.published.map(\.format), [.json, .svg, .markdown])

        let json = try read(targetPath(.json))
        XCTAssertTrue(json.contains("\"x\": 10"), "the earlier stroke must remain exported")
        XCTAssertTrue(json.contains("\"x\": 20"))
        XCTAssertFalse(
            backupExists(.json),
            "an export that only adds strokes must not create a backup"
        )
        XCTAssertFalse(backupExists(.svg), "a regenerated drawing needs no history")
        XCTAssertFalse(backupExists(.markdown), "a regenerated page needs no history")
    }

    func testAJSONThatLostAStrokeIsPreservedBeforeReplacement() async throws {
        let publisher = FilePenExportPublisher()
        _ = await publisher.publish(request(), content: content([stroke(x: 10), stroke(x: 20)]))
        let earlier = try read(targetPath(.json))

        // The library no longer holds the x=10 stroke, so the old record holds
        // data the new export cannot reproduce.
        let report = await publisher.publish(request(), content: content(x: 20))

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(
            try read(backupPath(.json, depth: 1)),
            earlier,
            "the record with the lost stroke must stay recoverable"
        )
        XCTAssertEqual(
            try read(targetPath(.json)),
            jsonText([stroke(x: 20)]),
            "the target follows the library, and no prior file data is merged into it"
        )
        XCTAssertFalse(
            backupExists(.svg),
            "the drawing is regenerated, so it needs no history even when it changes"
        )
    }

    func testALostDuplicateStrokeOccurrenceIsPreserved() async throws {
        let publisher = FilePenExportPublisher()
        // Two strokes with identical content: the library retained both, so the
        // record legitimately holds two occurrences of one stroke.
        _ = await publisher.publish(request(), content: content([stroke(x: 10), stroke(x: 10)]))
        let earlier = try read(targetPath(.json))

        let report = await publisher.publish(request(), content: content(x: 10))

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(
            try read(backupPath(.json, depth: 1)),
            earlier,
            "losing one of two identical occurrences is still a loss"
        )
        XCTAssertEqual(try read(targetPath(.json)), jsonText([stroke(x: 10)]))
    }

    func testAJSONTargetThisBuildCannotCompareIsPreserved() async throws {
        let publisher = FilePenExportPublisher()
        let handWritten = "{\n  \"formatVersion\": 99,\n  \"note\": \"a later build\"\n}\n"
        try write(handWritten, to: targetPath(.json))

        let report = await publisher.publish(request(), content: content(x: 10))

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(try read(backupPath(.json, depth: 1)), handWritten)
        XCTAssertEqual(try read(targetPath(.json)), jsonText([stroke(x: 10)]))
    }

    func testAJSONTargetOfAnotherPageIsPreserved() async throws {
        let publisher = FilePenExportPublisher()
        let otherPage = PageIdentity(section: 3, owner: 27, book: 700, page: 2)
        let other = String(
            decoding: JSONPageRenderer.render(
                PageExportDocument(page: otherPage, strokes: [stroke(x: 10)])
            ),
            as: UTF8.self
        )
        try write(other, to: targetPath(.json))

        let report = await publisher.publish(request(), content: content(x: 10))

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(
            try read(backupPath(.json, depth: 1)),
            other,
            "a record of another page is kept rather than compared"
        )
        XCTAssertEqual(try read(targetPath(.json)), jsonText([stroke(x: 10)]))
    }

    func testARecordWhoseReportedOriginTimeChangedIsPreserved() async throws {
        let publisher = FilePenExportPublisher()
        _ = await publisher.publish(
            request(),
            content: content([stroke(x: 10, origin: .unreliable(reportedMilliseconds: nil))])
        )
        let earlier = try read(targetPath(.json))
        XCTAssertTrue(
            earlier.contains("\"originTimeMilliseconds\": null"),
            "the first record must carry an absent reported time"
        )

        // The library now reports zero for the same mark. The two records say
        // different things, so the file's version is not redundant.
        let report = await publisher.publish(
            request(),
            content: content([stroke(x: 10, origin: .unreliable(reportedMilliseconds: 0))])
        )

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(
            try read(backupPath(.json, depth: 1)),
            earlier,
            "a record whose reported origin time changed must be preserved"
        )
        XCTAssertTrue(try read(targetPath(.json)).contains("\"originTimeMilliseconds\": 0"))
    }

    func testBackupFilesAnEarlierReleaseLeftAreLeftInPlace() async throws {
        let publisher = FilePenExportPublisher()
        _ = await publisher.publish(request(), content: content(x: 10))

        // What an earlier release left beside each generated file, because it filed
        // a backup for every format.
        var legacy: [String: String] = [:]
        for format in [PenExportFormat.svg, .markdown] {
            for depth in 1...3 {
                let path = backupPath(format, depth: depth)
                let text = "\(format.fileExtension) backup \(depth)\n"
                try write(text, to: path)
                legacy[path] = text
            }
        }

        // A later export replaces both generated files.
        let report = await publisher.publish(
            request(),
            content: content([stroke(x: 10), stroke(x: 20)])
        )

        XCTAssertEqual(report.published.map(\.format), [.json, .svg, .markdown])
        for (path, text) in legacy {
            XCTAssertEqual(try read(path), text, "\(path) must be left exactly as it is")
        }
    }

    func testAChangedDrawingAndPageAreReplacedWithoutBackups() async throws {
        let publisher = FilePenExportPublisher()
        _ = await publisher.publish(request(), content: content(x: 10))
        let drawing = try read(targetPath(.svg))
        let page = try read(targetPath(.markdown))

        let report = await publisher.publish(
            request(),
            content: content([stroke(x: 10), stroke(x: 20)])
        )

        XCTAssertEqual(report.published.map(\.format), [.json, .svg, .markdown])
        XCTAssertNotEqual(try read(targetPath(.svg)), drawing)
        XCTAssertNotEqual(try read(targetPath(.markdown)), page)

        for format in [PenExportFormat.svg, .markdown] {
            XCTAssertFalse(backupExists(format), "\(format) must never file a backup")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: backupPath(format, depth: 3)),
                "\(format) must never rotate a backup history"
            )
        }
    }

    func testASymlinkInAnUnusedBackupSlotDoesNotBlockAGeneratedFormat() async throws {
        let publisher = FilePenExportPublisher()
        _ = await publisher.publish(request(), content: content(x: 10))

        // A link left beside a drawing by an older release: the drawing's current
        // policy never touches that slot, so the export must not be refused for it.
        let outside = directory.url.appendingPathComponent("outside.svg")
        try write("outside\n", to: outside.path)
        let slot = backupPath(.svg, depth: 1)
        try FileManager.default.createSymbolicLink(atPath: slot, withDestinationPath: outside.path)

        let report = await publisher.publish(request(), content: content(x: 20))

        XCTAssertTrue(report.succeeded, "an unused backup slot is not a hazard")
        XCTAssertEqual(report.published.map(\.format), [.json, .svg])
        XCTAssertEqual(try read(outside.path), "outside\n", "the link target must not be written")
        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(atPath: slot),
            "the unused link must be left where it is"
        )
    }

    func testASymlinkedTargetIsRefusedAndLeftAlone() async throws {
        let publisher = FilePenExportPublisher()
        let outside = directory.url.appendingPathComponent("outside.json")
        try write("outside content\n", to: outside.path)

        let path = targetPath(.json)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: outside.path)

        let report = await publisher.publish(request(), content: content(x: 10))

        XCTAssertFalse(report.succeeded)
        let json = try XCTUnwrap(report.artifacts.first { $0.format == .json })
        XCTAssertEqual(json.status, .failed(reason: "\(path) is a symbolic link, which this build does not follow"))
        XCTAssertEqual(try read(outside.path), "outside content\n", "the link target must not be written")
        XCTAssertTrue(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil,
            "the symlink itself must be left in place"
        )
    }

    func testASymlinkedBackupSlotIsRefused() async throws {
        let publisher = FilePenExportPublisher()
        _ = await publisher.publish(request(), content: content(x: 10))

        let path = targetPath(.json)
        let outside = directory.url.appendingPathComponent("outside.json")
        try write("outside content\n", to: outside.path)
        try FileManager.default.createSymbolicLink(
            atPath: "\(path).bak1",
            withDestinationPath: outside.path
        )

        let before = try read(path)
        let report = await publisher.publish(request(), content: content(x: 20))

        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(try read(path), before, "the target must not change when a backup slot is a link")
        XCTAssertEqual(try read(outside.path), "outside content\n")
    }

    func testBackupPreservationFailureLeavesTheTargetUntouched() async throws {
        let publisher = FilePenExportPublisher()
        _ = await publisher.publish(request(), content: content(x: 10))

        // The history cannot rotate when every slot is an occupied directory, so
        // preservation fails before the target is touched. An unusable slot
        // stands in for a full disk or a directory that cannot be written.
        let path = targetPath(.json)
        for depth in [1, 2, 3] {
            try FileManager.default.createDirectory(
                atPath: "\(path).bak\(depth)",
                withIntermediateDirectories: false
            )
            try write("occupied\n", to: "\(path).bak\(depth)/occupied")
        }
        let before = try read(path)

        let report = await publisher.publish(request(), content: content(x: 20))

        XCTAssertFalse(report.succeeded)
        let json = try XCTUnwrap(report.artifacts.first { $0.format == .json })
        XCTAssertNotNil(json.failureReason)
        XCTAssertEqual(try read(path), before, "the target keeps its complete prior content")
    }

    func testAMissingDestinationFailsEveryTargetWithAReason() async throws {
        let publisher = FilePenExportPublisher()
        let missing = directory.url.appendingPathComponent("not-created")
        let report = await publisher.publish(
            PenExportRequest(pages: [page], destinationDirectory: missing.path),
            content: content(x: 10)
        )

        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.failed.count, 3)
        for artifact in report.failed {
            XCTAssertEqual(
                artifact.failureReason,
                "the destination directory \(missing.path) does not exist"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testOneFailingTargetStillReportsTheOthers() async throws {
        let publisher = FilePenExportPublisher()
        let outside = directory.url.appendingPathComponent("outside.svg")
        try write("outside\n", to: outside.path)
        try FileManager.default.createSymbolicLink(
            atPath: targetPath(.svg),
            withDestinationPath: outside.path
        )

        let report = await publisher.publish(request(), content: content(x: 10))

        XCTAssertFalse(report.succeeded, "the whole export is not successful while a target failed")
        XCTAssertEqual(report.published.map(\.format), [.json, .markdown])
        XCTAssertEqual(report.failed.map(\.format), [.svg])
        XCTAssertEqual(try read(outside.path), "outside\n")
    }

    func testARetryCompletesTheSetAfterATargetFailed() async throws {
        let publisher = FilePenExportPublisher()
        let outside = directory.url.appendingPathComponent("outside.svg")
        try write("outside\n", to: outside.path)
        let link = targetPath(.svg)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside.path)

        let first = await publisher.publish(request(), content: content(x: 10))
        XCTAssertFalse(first.succeeded)

        try FileManager.default.removeItem(atPath: link)
        let retry = await publisher.publish(request(), content: content(x: 10))

        XCTAssertTrue(retry.succeeded, "a retry completes all three targets")
        XCTAssertEqual(retry.published.map(\.format), [.svg], "the two written files are left unchanged")
        XCTAssertEqual(retry.unchanged.map(\.format), [.json, .markdown])
    }

    func testOrphanedTemporaryFilesAreRemovedOnRetry() async throws {
        let publisher = FilePenExportPublisher()
        let path = targetPath(.json)

        // What an interrupted publication leaves behind.
        try write("partial", to: "\(path).tmp-\(UUID().uuidString)")
        try write("partial", to: "\(path).bak-tmp-\(UUID().uuidString)")

        let report = await publisher.publish(request(), content: content(x: 10))

        XCTAssertTrue(report.succeeded)
        let leftovers = try entries().filter { $0.contains(".tmp-") }
        XCTAssertEqual(leftovers, [], "a retry must clean up orphaned temporary files")
    }

    func testTheFileOnDiskIsNeverPartial() async throws {
        let publisher = FilePenExportPublisher()
        _ = await publisher.publish(request(), content: content(x: 10))

        let first = try read(targetPath(.json))
        _ = await publisher.publish(request(), content: content(x: 20))
        let second = try read(targetPath(.json))

        // Both versions are complete records: the replacement is a rename, so no
        // reader can observe a half-written file.
        for rendered in [first, second] {
            XCTAssertTrue(rendered.hasPrefix("{"))
            XCTAssertTrue(rendered.hasSuffix("}\n"))
        }
        XCTAssertNotEqual(first, second)
    }

    func testPublicationUsesTheRequestedFormats() async throws {
        let publisher = FilePenExportPublisher()
        let report = await publisher.publish(
            PenExportRequest(
                formats: [.json],
                pages: [page],
                destinationDirectory: directory.url.path
            ),
            content: content(x: 10)
        )

        XCTAssertEqual(report.artifacts.map(\.format), [.json])
        XCTAssertEqual(try entries(), ["ncode-s3-o27-b700-p1.json"])
    }

    func testEveryPageIsPublishedBeforeTheNextOne() async throws {
        let publisher = FilePenExportPublisher()
        let second = PageIdentity(section: 1, owner: 1, book: 1, page: 1)

        let report = await publisher.publish(
            PenExportRequest(pages: [page, second], destinationDirectory: directory.url.path),
            content: [
                PenPageContent(page: page, strokes: [stroke(x: 1)]),
                PenPageContent(page: second, strokes: [stroke(x: 2)]),
            ]
        )

        XCTAssertEqual(
            report.artifacts.map { URL(fileURLWithPath: $0.path).lastPathComponent },
            [
                "ncode-s1-o1-b1-p1.json",
                "ncode-s1-o1-b1-p1.svg",
                "ncode-s1-o1-b1-p1.md",
                "ncode-s3-o27-b700-p1.json",
                "ncode-s3-o27-b700-p1.svg",
                "ncode-s3-o27-b700-p1.md",
            ],
            "pages are published in canonical order"
        )
    }
}
