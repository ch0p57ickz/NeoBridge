import AppKit
import NeoBridgeMacCore
import NeoCore
import NeoStorage
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
        do {
            if let options = try PenAcceptanceOptions(
                environment: ProcessInfo.processInfo.environment
            ) {
                NeoBridgeAcceptance.run(options: options)
            }
        } catch {
            let message = (error as? PenAcceptanceOptions.ParseError)?.message
                ?? String(describing: error)
            FileHandle.standardError.write(
                Data("acceptance: \(message)\n".utf8)
            )
            exit(2)
        }
        NeoBridgeMacApp.main()
    }
}

/// Builds the objects the app runs.
///
/// One Bluetooth adapter serves a whole run, because only one pen connects at a
/// time. Each attempt still gets its own transport and session from the factory,
/// which is what makes a retry a new scan rather than a resumed one. One library
/// serves the whole run, because the strokes belong to the user rather than to an
/// attempt.
@MainActor
enum PenSyncAppComposition {
    /// Creates the controller the app and the acceptance run drive.
    ///
    /// - Parameters:
    ///   - trace: An optional traffic transcript. Only the acceptance run
    ///     supplies one.
    ///   - exportDirectory: A folder fixed at launch, or `nil` to use the folder
    ///     the user chose.
    ///   - acceptance: The options a headless run varies the attempt with, or
    ///     `nil` for the app's own behaviour. The interface never supplies them.
    static func makeController(
        trace: PenTrafficLog? = nil,
        exportDirectory: String? = nil,
        acceptance: PenAcceptanceOptions? = nil
    ) -> PenSyncController {
        let central = CoreBluetoothPenCentral()
        let destination: any PenExportDestinationProviding = exportDirectory.map {
            FixedExportDestination(directory: $0)
        } ?? BookmarkedExportDestination()
        let library = makeLibrary()

        return PenSyncController(
            runners: PenSyncRunnerFactory { selection in
                BluetoothPenSyncRunner(
                    central: central,
                    selection: selection,
                    transferOption: acceptance?.transferOption ?? .nextAndReserve,
                    packetBarrier: library.deletingReadStorage.barrier,
                    abortAtPacket: acceptance?.abortAtPacket,
                    trace: trace
                )
            },
            library: library.coordinator,
            destination: destination,
            deletingReadStorage: library.deletingReadStorage
        )
    }

    /// Opens the durable library, or an assembly that reports why it could not.
    private static func makeLibrary() -> PenLibraryAssembly {
        let url: URL
        do {
            url = try PenLibraryComposition.defaultLibraryURL()
        } catch {
            return unavailableAssembly(
                path: "Application Support/NeoBridge/library.sqlite",
                reason: String(describing: error)
            )
        }

        do {
            return try PenLibraryComposition.makeAssembly(libraryURL: url)
        } catch {
            let message = (error as? StorageError)?.message ?? String(describing: error)
            return unavailableAssembly(path: url.path, reason: message)
        }
    }

    /// An assembly whose coordinator refuses every read and whose deleting route
    /// is closed, for a library that could not be opened.
    private static func unavailableAssembly(path: String, reason: String) -> PenLibraryAssembly {
        PenLibraryAssembly(
            coordinator: UnavailableImportCoordinator(libraryPath: path, reason: reason),
            deletingReadStorage: PenDeletingReadStorage(
                barrier: nil,
                unavailableReason: reason
            )
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
        .defaultSize(width: 520, height: 520)
        .windowResizability(.contentMinSize)
    }
}
