import Foundation
import NeoCore

/// The content the status-bar menu shows for the controller's current state.
///
/// The mapping from controller state to menu content lives in the core so it can be
/// tested without rendering a menu: the AppKit menu builder in `NeoBridgeMac` and the
/// XCTest suite both read it. Keeping it here is what lets the menu remain a thin
/// adapter over the controller instead of a second place where the presentation rules
/// are stated.
public struct PenSyncMenuPresentation: Equatable, Sendable {
    /// One saved-mode choice and whether its checkmark is on.
    public struct ModeItem: Equatable, Sendable {
        /// The setting the item selects.
        public let mode: PenSyncMode

        /// The title the item shows.
        public let title: String

        /// Whether the item is the saved mode.
        public let isSelected: Bool
    }

    /// One saved-interval choice and whether its checkmark is on.
    public struct IntervalItem: Equatable, Sendable {
        /// The setting the item selects.
        public let interval: PenSyncInterval

        /// The title the item shows.
        public let title: String

        /// Whether the item is the saved interval.
        public let isSelected: Bool
    }

    /// One pen the user can choose between, without its address.
    public struct PenItem: Equatable, Sendable {
        /// The numbered label the item shows.
        public let label: String

        /// The peripheral the item reads.
        public let peripheral: PenPeripheral
    }

    /// The single status line, as disabled menu text.
    public let status: String

    /// The saved-mode choices, always present.
    public let modes: [ModeItem]

    /// The saved-interval choices, always present.
    public let intervals: [IntervalItem]

    /// Whether **Sync Now** can start a read now.
    public let isSyncNowEnabled: Bool

    /// Whether **Cancel Read** is offered.
    public let isCancelVisible: Bool

    /// Whether the pen-choice block is offered.
    public let isChoosingPen: Bool

    /// The pens offered for choice, numbered rather than addressed.
    public let pens: [PenItem]

    /// Whether **Retry Export** is offered.
    public let isRetryExportVisible: Bool

    /// Reads the menu content the controller's state calls for.
    ///
    /// - Parameters:
    ///   - controller: The controller whose state is shown.
    ///   - now: The moment the relative status line is dated against.
    @MainActor
    public static func make(
        from controller: PenSyncController,
        at now: Date
    ) -> PenSyncMenuPresentation {
        PenSyncMenuPresentation(
            status: controller.menuStatus.label(at: now),
            modes: PenSyncMode.allCases.map { mode in
                ModeItem(mode: mode, title: mode.title, isSelected: controller.syncMode == mode)
            },
            intervals: PenSyncInterval.allCases.map { interval in
                IntervalItem(
                    interval: interval,
                    title: interval.title,
                    isSelected: controller.syncInterval == interval
                )
            },
            isSyncNowEnabled: !controller.isBusy && !controller.isAwaitingChoice,
            isCancelVisible: controller.isBusy,
            isChoosingPen: controller.isAwaitingChoice,
            pens: controller.penCandidates.enumerated().map { index, pen in
                PenItem(label: Self.label(for: pen, at: index), peripheral: pen)
            },
            isRetryExportVisible: controller.canRetryExport
        )
    }

    /// Names a candidate without exposing its Bluetooth address.
    ///
    /// On macOS a CoreBluetooth identifier is derived from the pen's address, so the
    /// menu numbers the candidates instead of printing one.
    public static func label(for pen: PenPeripheral, at index: Int) -> String {
        "\(pen.name ?? "Pen") (pen \(index + 1))"
    }
}

extension PenSyncController.MenuStatus {
    /// The one-line status the menu shows, dating a completed read relative to `now`.
    ///
    /// - Parameter now: The moment a completed read's elapsed time is measured against.
    ///   Passing it in keeps the label testable and keeps the menu the only place that
    ///   decides when to refresh it.
    public func label(at now: Date) -> String {
        switch self {
        case .idle: return "Idle"
        case .syncing: return "Syncing"
        case .paused: return "Paused"
        case .synced(let date): return "Synced " + Self.elapsed(from: date, to: now)
        case .notDetected: return "Not Detected"
        case .failed: return "Failed"
        }
    }

    /// A relative description of a completed read, such as "3 minutes ago".
    ///
    /// A read stored in the future, which only a clock change can produce, reads as
    /// "just now" rather than as a negative interval.
    static func elapsed(from date: Date, to now: Date) -> String {
        guard now.timeIntervalSince(date) >= 1 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
