import Foundation
import NeoBridgeMacCore
import XCTest

/// Tests for the export folder the app remembers.
///
/// The bookmark is what lets a chosen folder survive a relaunch, so the tests use
/// their own `UserDefaults` suite and never touch the user's.
@MainActor
final class PenExportDestinationTests: XCTestCase {
    func testRemembersAChosenFolderAndReopensIt() throws {
        let suiteName = "NeoBridge.exportFolderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("neobridge-export-destination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let expected = folder.resolvingSymlinksInPath().path
        let first = BookmarkedExportDestination(defaults: defaults)
        XCTAssertFalse(first.isConfigured)
        XCTAssertNil(first.exportDirectory())

        try first.setExportDirectory(folder)
        XCTAssertTrue(first.isConfigured)
        XCTAssertEqual(first.exportDirectory().map(resolvedPath), expected)

        // A fresh instance with the same defaults is what a relaunch looks like:
        // the folder must reopen without a new picker.
        let relaunched = BookmarkedExportDestination(defaults: defaults)
        XCTAssertTrue(relaunched.isConfigured)
        XCTAssertEqual(relaunched.exportDirectory().map(resolvedPath), expected)
    }

    /// Resolves a stored path the way the bookmark does, since `/var` is a
    /// symlink to `/private/var` on macOS.
    private func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func testNoFolderIsConfiguredUntilOneIsChosen() {
        let destination = NoExportDestination()
        XCTAssertFalse(destination.isConfigured)
        XCTAssertNil(destination.exportDirectory())
    }

    func testFixedDestinationAlwaysReportsItsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.path
        let destination = FixedExportDestination(directory: folder)
        XCTAssertTrue(destination.isConfigured)
        XCTAssertEqual(destination.exportDirectory(), folder)

        let replacement = URL(fileURLWithPath: "/tmp/neobridge-fixed-\(UUID().uuidString)")
        try destination.setExportDirectory(replacement)
        XCTAssertEqual(destination.exportDirectory(), replacement.path)
    }
}
