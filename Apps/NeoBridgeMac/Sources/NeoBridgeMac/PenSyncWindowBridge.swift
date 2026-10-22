import SwiftUI

/// Carries SwiftUI's window-opening action to the AppKit status item.
///
/// The status item is AppKit, so it cannot read SwiftUI's `openWindow` environment
/// value directly. A scene command captures the action at launch and deposits it here,
/// so **Connection Details…** can open the window on the first click and after the user
/// closes and reopens it.
@MainActor
final class PenSyncWindowBridge {
    /// The process-wide bridge.
    static let shared = PenSyncWindowBridge()

    /// Opens the window with a scene identifier, once the scene command has appeared.
    var openWindow: (@MainActor (String) -> Void)?

    private init() {}
}

/// Captures SwiftUI's window-opening action for the AppKit status item.
///
/// It is installed in the window scene's command group, which is built at launch even
/// though the window starts closed.
struct PenSyncOpenWindowCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                PenSyncWindowBridge.shared.openWindow = { id in openWindow(id: id) }
            }
    }
}
