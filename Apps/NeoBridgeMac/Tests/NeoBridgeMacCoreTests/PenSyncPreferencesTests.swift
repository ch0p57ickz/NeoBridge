import Foundation
import NeoBridgeMacCore
import XCTest

/// Tests for the saved sync settings.
///
/// Every test uses its own defaults suite, so no test reads or writes the
/// settings a person has saved, and the export-folder bookmark is checked to be
/// untouched by the sync settings that live beside it.
@MainActor
final class PenSyncPreferencesTests: XCTestCase {
    func testFirstInstallDefaultsToDeleteAndFiveMinutes() {
        let (preferences, _, _) = makePreferences()

        XCTAssertEqual(preferences.mode, .delete)
        XCTAssertEqual(preferences.interval, .fiveMinutes)
    }

    func testASavedSettingIsRestored() {
        let (preferences, defaults, suiteName) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for mode in PenSyncMode.allCases {
            preferences.mode = mode
            XCTAssertEqual(PenSyncPreferences(defaults: defaults).mode, mode)
        }

        for interval in PenSyncInterval.allCases {
            preferences.interval = interval
            XCTAssertEqual(PenSyncPreferences(defaults: defaults).interval, interval)
        }
    }

    func testUnrecognizedStoredValuesFallBackToTheDefaults() {
        let (_, defaults, suiteName) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("retainEverything", forKey: PenSyncPreferences.modeDefaultsKey)
        defaults.set(7, forKey: PenSyncPreferences.intervalDefaultsKey)

        let preferences = PenSyncPreferences(defaults: defaults)
        XCTAssertEqual(preferences.mode, .delete)
        XCTAssertEqual(preferences.interval, .fiveMinutes)
    }

    func testTheSyncSettingsLeaveTheExportBookmarkAlone() throws {
        let (preferences, defaults, suiteName) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("neobridge-preferences-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let destination = BookmarkedExportDestination(defaults: defaults)
        try destination.setExportDirectory(folder)
        let bookmark = try XCTUnwrap(defaults.data(forKey: BookmarkedExportDestination.bookmarkDefaultsKey))

        preferences.mode = .retain
        preferences.interval = .thirtyMinutes

        XCTAssertEqual(
            defaults.data(forKey: BookmarkedExportDestination.bookmarkDefaultsKey),
            bookmark,
            "the sync settings must not disturb the export folder"
        )
        // The resolved path may be the same folder through a symlinked prefix, so
        // the folder itself is what is compared.
        XCTAssertTrue(destination.isConfigured)
        let resolved = try XCTUnwrap(destination.exportDirectory())
        XCTAssertEqual(URL(fileURLWithPath: resolved).lastPathComponent, folder.lastPathComponent)
    }

    func testAModeStatesWhatItDoesWithThePensCopy() {
        XCTAssertTrue(PenSyncMode.delete.isAutomatic)
        XCTAssertTrue(PenSyncMode.retain.isAutomatic)
        XCTAssertFalse(PenSyncMode.paused.isAutomatic, "Paused starts no read")

        XCTAssertEqual(PenSyncMode.delete.cleanupMode, .deleteAfterAcknowledge)
        XCTAssertEqual(PenSyncMode.retain.cleanupMode, .keepOnPen)
        XCTAssertNil(PenSyncMode.paused.cleanupMode, "Paused asks for no transfer")
    }

    func testTheThreeModeTitlesNameTheActionTheySelect() {
        // The third title is the action rather than the state, so the three settings
        // read as one choice; "paused" is what the app reports once it is selected.
        XCTAssertEqual(
            PenSyncMode.allCases.map(\.title),
            ["Sync and Delete", "Sync and Retain", "Pause"]
        )
    }

    func testEveryOfferedIntervalIsTheFourTheMenuShows() {
        XCTAssertEqual(
            PenSyncInterval.allCases.map(\.rawValue),
            [1, 5, 15, 30]
        )
        XCTAssertEqual(PenSyncInterval.oneMinute.duration, .seconds(60))
        XCTAssertEqual(PenSyncInterval.thirtyMinutes.duration, .seconds(1800))
        XCTAssertEqual(PenSyncInterval.oneMinute.title, "1 minute")
        XCTAssertEqual(PenSyncInterval.fiveMinutes.title, "5 minutes")
    }

    /// Creates a store over its own defaults suite.
    private func makePreferences() -> (PenSyncPreferences, UserDefaults, String) {
        let suiteName = "NeoBridgePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (PenSyncPreferences(defaults: defaults), defaults, suiteName)
    }
}
