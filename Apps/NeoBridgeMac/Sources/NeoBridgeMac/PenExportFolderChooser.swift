import AppKit
import NeoBridgeMacCore

/// Asks the user for the folder exports are written to.
///
/// The chosen folder is stored as a security-scoped bookmark, so it survives a
/// relaunch and keeps working if the app is sandboxed later. The panel is the only
/// place the app asks for a path; everything below it takes a resolved directory.
@MainActor
enum PenExportFolderChooser {
    /// Shows the folder picker and stores the choice.
    ///
    /// - Parameter controller: The controller that owns the destination.
    /// - Returns: A message to show when the choice could not be stored.
    @discardableResult
    static func choose(into controller: PenSyncController) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder NeoBridge writes page files into."
        if let current = controller.exportDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            try controller.chooseExportDirectory(url)
            return nil
        } catch {
            return "The folder could not be remembered: \(error)"
        }
    }
}
