import AppKit
import NeoBridgeMacCore
import SwiftUI

/// The scene identifier and title that name the details window.
enum PenSyncScene {
    static let windowID = "pen-sync"

    /// The title the details window shows.
    static let windowTitle = "NeoBridge Pen Sync"
}

/// The process entry point.
///
/// The app normally runs as the menu-bar UI. When the acceptance environment
/// variable is set, the same binary runs one headless read attempt against the
/// physical pen instead and writes its traffic transcript, which is what
/// `Tests/Hardware/README.md` needs and what a menu-bar UI cannot be driven into
/// from a script without an accessibility grant.
@main
enum NeoBridgeMacMain {
    static func main() {
        if let traceURL = NeoBridgeAcceptance.traceURL {
            NeoBridgeAcceptance.run(traceURL: traceURL)
        }
        NeoBridgeMacApp.main()
    }
}

/// Builds the objects the app runs.
///
/// One Bluetooth adapter serves a whole run, because only one pen connects at a
/// time. Each attempt still gets its own transport and session from the factory,
/// which is what makes a retry a new scan rather than a resumed one.
@MainActor
enum PenSyncAppComposition {
    /// Creates the controller the app and the acceptance run drive.
    ///
    /// - Parameter trace: An optional traffic transcript. Only the acceptance run
    ///   supplies one.
    static func makeController(trace: PenTrafficLog? = nil) -> PenSyncController {
        let central = CoreBluetoothPenCentral()
        return PenSyncController(
            runners: PenSyncRunnerFactory { selection in
                BluetoothPenSyncRunner(central: central, selection: selection, trace: trace)
            }
        )
    }
}

/// The menu-bar app.
///
/// The app runs as an accessory: `Info.plist` sets `LSUIElement`, so there is no
/// Dock icon and no window until the user asks for one. All state lives in one
/// ``PenSyncController``; the menu and the window are two views of it.
struct NeoBridgeMacApp: App {
    @State private var controller = PenSyncAppComposition.makeController()
    @State private var activation = PenSyncActivation()

    var body: some Scene {
        MenuBarExtra("NeoBridge", systemImage: "pencil.tip") {
            PenSyncMenu(controller: controller, activation: activation)
        }
        .menuBarExtraStyle(.menu)

        Window(PenSyncScene.windowTitle, id: PenSyncScene.windowID) {
            PenSyncView(controller: controller)
        }
        .defaultSize(width: 480, height: 460)
        .windowResizability(.contentMinSize)
    }
}
