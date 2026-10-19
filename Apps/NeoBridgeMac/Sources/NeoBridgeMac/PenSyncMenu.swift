import AppKit
import NeoBridgeMacCore
import SwiftUI

/// The menu-bar item's commands and status.
///
/// A `.menu` style `MenuBarExtra` renders only menu items, so the status appears
/// as disabled text and every command is a `Button`.
struct PenSyncMenu: View {
    @Environment(\.openWindow) private var openWindow
    let controller: PenSyncController

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

        if let result = controller.result {
            if result.isEmpty {
                Text("The pen reported no offline note to read.")
            }
            Text(Self.summary(for: result))
        }

        if let message = controller.errorMessage {
            Text(message)
        }

        Divider()
        Button("Connection Details…") { openWindow(id: PenSyncScene.windowID) }
        Divider()
        Button("Quit NeoBridge") { NSApplication.shared.terminate(nil) }
    }

    /// Names a candidate without exposing its Bluetooth address.
    ///
    /// On macOS a CoreBluetooth identifier is derived from the pen's address, so
    /// the menu numbers the candidates instead of printing one.
    private static func label(for pen: PenPeripheral, at index: Int) -> String {
        "\(pen.name ?? "Pen") (pen \(index + 1))"
    }

    private static func summary(for result: PenSyncSummary) -> String {
        "\(result.strokeCount) strokes · \(result.dotCount) dots · \(result.distinctPageCount) pages"
    }
}
