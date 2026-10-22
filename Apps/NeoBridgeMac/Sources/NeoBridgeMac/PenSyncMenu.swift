import AppKit
import NeoBridgeMacCore
import NeoCore
import SwiftUI

/// The menu-bar item's status, settings, and contextual commands.
///
/// A `.menu` style `MenuBarExtra` renders only menu items, so the status appears as
/// disabled text and every command is a `Button`. The menu holds one compact status
/// line, the saved sync settings, and the actions that apply to the sync in
/// progress; counts, export paths, cleanup explanations, and failure detail live in
/// Connection Details, so the menu stays a control surface rather than a report.
struct PenSyncMenu: View {
    @Environment(\.openWindow) private var openWindow
    let controller: PenSyncController
    let activation: PenSyncActivation

    var body: some View {
        statusText
        Divider()

        ForEach(PenSyncMode.allCases, id: \.self) { mode in
            Toggle(mode.title, isOn: binding(for: mode))
        }

        Menu("Sync Interval") {
            ForEach(PenSyncInterval.allCases, id: \.self) { interval in
                Toggle(interval.title, isOn: binding(for: interval))
            }
        }

        if controller.isBusy {
            Divider()
            Button("Cancel Read") { controller.cancel() }
        }

        if controller.isAwaitingChoice {
            Divider()
            Text("Choose a pen")
            ForEach(Array(controller.penCandidates.enumerated()), id: \.element.id) { index, pen in
                Button(Self.label(for: pen, at: index)) { controller.choosePen(pen) }
            }
        }

        if controller.canRetryExport {
            Divider()
            Button(PenSyncController.retryExportActionTitle) { controller.retryExport() }
        }

        Divider()
        Button("Connection Details…") { openDetailsWindow() }
        Divider()
        Button("Quit NeoBridge") { NSApplication.shared.terminate(nil) }
    }

    /// The one-line status, as disabled menu text.
    ///
    /// The synced case is built from a date style rather than from a formatted
    /// string, so the elapsed time stays correct without the app republishing
    /// anything: SwiftUI updates a relative date as time passes. The style already
    /// reads "3 minutes ago", so nothing is appended to it.
    private var statusText: Text {
        switch controller.menuStatus {
        case .idle:
            return Text("Idle")
        case .syncing:
            return Text("Syncing")
        case .paused:
            return Text("Paused")
        case .synced(let date):
            return Text("Synced ") + Text(date, style: .relative)
        case .notDetected:
            return Text("Not Detected")
        case .failed:
            return Text("Failed")
        }
    }

    /// A checkmark binding for one mode.
    ///
    /// Clicking the selected mode clears its checkmark, which is not a setting the
    /// app has, so the clear is ignored: the three modes are one choice, and only
    /// selecting a different one changes it.
    private func binding(for mode: PenSyncMode) -> Binding<Bool> {
        Binding(
            get: { controller.syncMode == mode },
            set: { isSelected in
                guard isSelected else { return }
                controller.selectSyncMode(mode)
            }
        )
    }

    /// A checkmark binding for one interval.
    private func binding(for interval: PenSyncInterval) -> Binding<Bool> {
        Binding(
            get: { controller.syncInterval == interval },
            set: { isSelected in
                guard isSelected else { return }
                controller.selectSyncInterval(interval)
            }
        )
    }

    /// Opens the details window and brings the app forward.
    ///
    /// Opening a window does not activate an accessory app, so without the
    /// activation the window is created behind the frontmost app and the command
    /// looks like it did nothing. The window makes itself key, and the activation
    /// takes focus and is re-asked as the menu dismissal and any Dock restore settle.
    private func openDetailsWindow() {
        openWindow(id: PenSyncScene.windowID)
        activation.activateForCommand()
    }

    /// Names a candidate without exposing its Bluetooth address.
    ///
    /// On macOS a CoreBluetooth identifier is derived from the pen's address, so
    /// the menu numbers the candidates instead of printing one.
    private static func label(for pen: PenPeripheral, at index: Int) -> String {
        "\(pen.name ?? "Pen") (pen \(index + 1))"
    }
}
