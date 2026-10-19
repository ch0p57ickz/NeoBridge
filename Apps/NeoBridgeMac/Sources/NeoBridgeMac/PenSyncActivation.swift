import AppKit

/// Brings this accessory app forward when the details window is opened from the menu.
///
/// A menu-bar item does not activate its app, so a window opened from its menu is
/// built behind the frontmost app and the command looks like it did nothing.
///
/// Asking for activation cooperatively is not enough. Measured on 2026-10-19 with a
/// throwaway accessory app whose window was minimized, another app frontmost, and
/// each API called in turn:
///
/// | Situation | `activate()` | `activate(ignoringOtherApps:)` |
/// | --- | --- | --- |
/// | window visible | declined | granted |
/// | window minimized | declined | granted |
/// | window mid-restore | declined | granted |
///
/// `activate(ignoringOtherApps:)` is deprecated in macOS 14 in favour of cooperative
/// activation, which the system declines for an app that is in the background exactly
/// as above. The header announces its removal with `API_TO_BE_DEPRECATED` rather than
/// an end date, and the cooperative replacement is the one that does not work here, so
/// the forced form is the one that is called. The user asked for the window, so taking
/// focus is what they asked for.
///
/// The activation is re-asked at the two events where macOS settles who is frontmost,
/// the end of the menu dismissal and the start of a Dock restore, because a settle can
/// undo a request made during it. The recorded runs do not separate the re-asks from
/// the command-time call: what they show is that with all of it in place, four commands
/// - including two minimize-and-restore cases - each ended with the app active and its
/// window the frontmost window. The observers are armed per command and removed when
/// one fires, so dismissing the menu without choosing a command does not activate the
/// app. A notification already queued when an observer is removed can still deliver
/// once, so the guarantee is at most one extra activation, which is idempotent.
@MainActor
final class PenSyncActivation {
    private var tokens: [NSObjectProtocol] = []

    /// Activates the app now, and again as the menu and any Dock restore settle.
    func activateForCommand() {
        activate()

        arm(NSMenu.didEndTrackingNotification)
        arm(NSWindow.didDeminiaturizeNotification)
    }

    /// Observes one notification once, activating a turn after it arrives.
    private func arm(_ name: Notification.Name) {
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.async { self?.activate() }
                self?.disarm()
            }
        }
        tokens.append(token)
    }

    private func disarm() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
    }

    private func activate() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
