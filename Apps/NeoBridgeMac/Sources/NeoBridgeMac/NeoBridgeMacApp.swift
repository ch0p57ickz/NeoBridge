import AppKit
import NeoBridgeMacCore
import NeoCore
import NeoStorage
import SwiftUI

/// The scene identifier and title that name the details window.
enum PenSyncScene {
    static let windowID = "pen-sync"

    /// The title the details window shows.
    static let windowTitle = "NeoBridge Connection Details"
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

/// The controller and the automatic schedule the app runs.
///
/// They are paired because they share one Bluetooth adapter: the radio runs one
/// scan at a time, so the schedule's observation and a read's selection scan have
/// to be handed off between the same central.
@MainActor
struct PenSyncRuntime {
    /// The controller the menu and the details window present.
    let controller: PenSyncController

    /// The schedule that discovers the pen and starts reads without a click.
    let coordinator: PenSyncCoordinator
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
    /// The runtime the interface presents, built and started once per process.
    ///
    /// The schedule starts with the app rather than with the first menu click, so
    /// discovery begins at launch. SwiftUI may create the app struct more than
    /// once, so the runtime is cached rather than rebuilt: a second one would open
    /// a second adapter and a second schedule.
    private static var cachedRuntime: PenSyncRuntime?

    /// Returns the app's runtime, starting its schedule the first time.
    static func runtime() -> PenSyncRuntime {
        if let cachedRuntime { return cachedRuntime }
        let built = buildRuntime()
        cachedRuntime = built
        built.coordinator.start()
        return built
    }

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
        makeController(
            central: CoreBluetoothPenCentral(),
            preferences: nil,
            trace: trace,
            exportDirectory: exportDirectory,
            acceptance: acceptance
        )
    }

    /// Creates the app's controller and schedule over one adapter.
    ///
    /// - Parameters:
    ///   - defaults: The domain the saved sync settings live in.
    ///   - clock: The clock the schedule measures intervals with.
    private static func buildRuntime(
        defaults: UserDefaults = .standard,
        clock: any PenSyncClock = ContinuousClock()
    ) -> PenSyncRuntime {
        let central = CoreBluetoothPenCentral()
        let controller = makeController(
            central: central,
            preferences: PenSyncPreferences(defaults: defaults),
            trace: nil,
            exportDirectory: nil,
            acceptance: nil
        )
        return PenSyncRuntime(
            controller: controller,
            coordinator: PenSyncCoordinator(central: central, controller: controller, clock: clock)
        )
    }

    /// Creates a controller over an adapter.
    ///
    /// - Parameter preferences: The saved sync settings, or `nil` for a run that is
    ///   driven directly and has no saved setting to honor. The acceptance run
    ///   supplies `nil`, so its deleting transfer stays behind its own explicit
    ///   confirmation.
    private static func makeController(
        central: any PenBluetoothCentral,
        preferences: PenSyncPreferences?,
        trace: PenTrafficLog?,
        exportDirectory: String?,
        acceptance: PenAcceptanceOptions?
    ) -> PenSyncController {
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
            deletingReadStorage: library.deletingReadStorage,
            preferences: preferences
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
/// ``PenSyncController`` and one ``PenSyncCoordinator``; the menu and the window
/// are two views of the controller, and the schedule is what starts reads.
struct NeoBridgeMacApp: App {
    @State private var runtime = PenSyncAppComposition.runtime()
    @State private var activation = PenSyncActivation()

    var body: some Scene {
        MenuBarExtra("NeoBridge", systemImage: "pencil.tip") {
            PenSyncMenu(controller: runtime.controller, activation: activation)
        }
        .menuBarExtraStyle(.menu)

        Window(PenSyncScene.windowTitle, id: PenSyncScene.windowID) {
            PenSyncView(controller: runtime.controller)
        }
        .defaultSize(width: 560, height: 620)
        .windowResizability(.contentMinSize)
    }
}
