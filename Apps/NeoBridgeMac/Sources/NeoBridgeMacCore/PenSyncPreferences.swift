import Foundation
import NeoCore

/// How the app syncs the pen without being asked each time.
///
/// The mode is the user's saved setting, not permission to delete: a saved
/// ``delete`` authorizes a deleting transfer for a read that passes every gate in
/// ``PenCleanupPolicy``, and a read that fails one of them keeps the pen's copy.
/// The gate stays data-driven, so the mode never stands in for evidence.
public enum PenSyncMode: String, Hashable, Sendable, CaseIterable {
    /// Sync and remove each acknowledged packet from the pen.
    case delete

    /// Sync and keep the pen's copy.
    case retain

    /// Stop discovering the pen and stop starting reads.
    case paused

    /// The title the menu shows for the setting.
    ///
    /// The three titles are named as the actions they select, so the setting reads
    /// as one choice rather than as a mode and two states: Pause is what the user
    /// picks, and "paused" is what the app then reports.
    public var title: String {
        switch self {
        case .delete: return "Sync and Delete"
        case .retain: return "Sync and Retain"
        case .paused: return "Pause"
        }
    }

    /// Whether this mode lets the app discover the pen and start reads.
    public var isAutomatic: Bool { self != .paused }

    /// The transfer intent this mode asks a read for, or `nil` when the mode starts
    /// no read at all.
    public var cleanupMode: PenCleanupMode? {
        switch self {
        case .delete: return .deleteAfterAcknowledge
        case .retain: return .keepOnPen
        case .paused: return nil
        }
    }
}

/// How long the app waits between automatic sync opportunities.
///
/// The menu offers exactly these four choices, so a stored value that is not one
/// of them is treated as absent rather than clamped to the nearest one.
public enum PenSyncInterval: Int, Hashable, Sendable, CaseIterable {
    /// Every minute.
    case oneMinute = 1

    /// Every five minutes. This is the first-install default.
    case fiveMinutes = 5

    /// Every fifteen minutes.
    case fifteenMinutes = 15

    /// Every thirty minutes.
    case thirtyMinutes = 30

    /// How long to wait between opportunities.
    public var duration: Duration { .seconds(rawValue * 60) }

    /// The title the menu shows for the interval.
    public var title: String {
        rawValue == 1 ? "1 minute" : "\(rawValue) minutes"
    }
}

/// The app's saved sync settings.
///
/// The two settings live beside the export-folder bookmark in `UserDefaults`, in
/// their own keys, so neither feature can disturb the other's stored value. An
/// absent key is the first-install state: ``PenSyncMode/delete`` and
/// ``PenSyncInterval/fiveMinutes``. A key that holds something this build does not
/// understand is treated as absent too, so a value written by a later build or by
/// hand never leaves the app without a usable setting.
@MainActor
public final class PenSyncPreferences {
    /// The key the saved mode lives under.
    public static let modeDefaultsKey = "NeoBridge.syncMode"

    /// The key the saved interval lives under, in minutes.
    public static let intervalDefaultsKey = "NeoBridge.syncIntervalMinutes"

    private let defaults: UserDefaults

    /// Creates a store over a defaults domain.
    ///
    /// - Parameter defaults: The domain the settings are read from and written to.
    ///   A test supplies its own so no test depends on, or disturbs, the settings a
    ///   person has saved.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved mode. Absent or unrecognized means Sync and Delete.
    public var mode: PenSyncMode {
        get {
            guard let raw = defaults.string(forKey: Self.modeDefaultsKey),
                let mode = PenSyncMode(rawValue: raw)
            else { return .delete }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.modeDefaultsKey)
        }
    }

    /// The saved interval. Absent or unrecognized means five minutes.
    public var interval: PenSyncInterval {
        get {
            guard let minutes = defaults.object(forKey: Self.intervalDefaultsKey) as? Int,
                let interval = PenSyncInterval(rawValue: minutes)
            else { return .fiveMinutes }
            return interval
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.intervalDefaultsKey)
        }
    }
}
