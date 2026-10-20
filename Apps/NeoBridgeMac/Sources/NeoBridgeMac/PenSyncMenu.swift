import AppKit
import NeoBridgeMacCore
import NeoCore
import SwiftUI

/// The menu-bar item's commands and status.
///
/// A `.menu` style `MenuBarExtra` renders only menu items, so the status appears
/// as disabled text and every command is a `Button`.
struct PenSyncMenu: View {
    @Environment(\.openWindow) private var openWindow
    @State private var folderMessage: String?
    let controller: PenSyncController
    let activation: PenSyncActivation

    var body: some View {
        Text("NeoBridge — \(controller.statusLabel)")

        if controller.isBusy {
            Button("Cancel Read") { controller.cancel() }
        } else {
            Button(PenSyncController.readActionTitle) { controller.readPenData() }
        }

        if controller.isAwaitingChoice {
            Text("Choose a pen")
            ForEach(Array(controller.penCandidates.enumerated()), id: \.element.id) { index, pen in
                Button(Self.label(for: pen, at: index)) { controller.choosePen(pen) }
            }
        }

        if let outcome = controller.outcome {
            if let state = controller.penState {
                Text("Battery: \(state.batteryLevel)% · \(state.isCharging ? "Charging" : "Not charging")")
                Text("Pen storage used: \(state.memoryUsed)%")
            }
            Text(Self.summary(for: outcome.summary))
            Text(outcome.notice)
            Text(outcome.cleanupNotice)
            if let export = outcome.export, !export.succeeded {
                ForEach(export.failed, id: \.path) { artifact in
                    Text(Self.failure(for: artifact))
                }
            }
        }

        if controller.canRetryExport {
            Button(PenSyncController.retryExportActionTitle) { controller.retryExport() }
        }

        if let message = controller.errorMessage {
            Text(message)
        }

        Divider()
        Text(PenSyncController.cleanupIntentStatement)
        Text(controller.cleanupIntentLine)
        if controller.canChooseCleanup {
            if controller.isCleanupIntended {
                Button(PenSyncController.retainPenDataTitle) { controller.retainPenDataForThisSync() }
            } else {
                Button("Remove Them After a Successful Read") { controller.intendCleanupForThisSync() }
            }
        }
        if let reason = controller.cleanupUnavailableReason {
            Text("Cleanup is unavailable: \(reason)")
        }

        Divider()
        Button("Choose Export Folder…") { folderMessage = PenExportFolderChooser.choose(into: controller) }
        Text(Self.folderLine(controller))
        if let folderMessage {
            Text(folderMessage)
        }

        Divider()
        Button("Connection Details…") { openDetailsWindow() }
        Divider()
        Button("Quit NeoBridge") { NSApplication.shared.terminate(nil) }
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

    private static func summary(for summary: PenSyncSummary) -> String {
        "\(summary.strokeCount) strokes · \(summary.dotCount) dots · \(summary.distinctPageCount) pages"
    }

    private static func failure(for artifact: PenExportArtifact) -> String {
        "\(URL(fileURLWithPath: artifact.path).lastPathComponent): \(artifact.failureReason ?? "not written")"
    }

    private static func folderLine(_ controller: PenSyncController) -> String {
        guard let path = controller.exportDirectoryPath else {
            return "No export folder chosen"
        }
        return "Exports go to \(path)"
    }
}
