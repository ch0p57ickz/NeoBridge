import AppKit
import NeoBridgeMacCore
import Observation

/// Owns the status-bar item and its native menu.
///
/// The menu is built with AppKit rather than a SwiftUI `.menu`-style `MenuBarExtra`
/// because that host recursed through `MenuBehavior.menuHostDidChangeMenuItems` while a
/// read changed state with the menu open, exhausting the main thread's stack. An
/// `NSStatusItem` with a plain `NSMenu` renders the same native menu and updates its
/// items in place while the menu is open, with no SwiftUI view graph in the update path.
///
/// The controller's state is the single source of truth: this type reads it through
/// ``PenSyncMenuPresentation`` and mirrors the result onto stable menu items, so the
/// menu never becomes a second place where the presentation rules are stated.
@MainActor
final class PenSyncMenuBarController: NSObject, NSMenuDelegate {
    private let controller: PenSyncController
    private let coordinator: PenSyncCoordinator
    private let activation: PenSyncActivation

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    /// The items whose content changes while the menu is open, in display order.
    private let statusCell = NSMenuItem()
    private let modesSeparator = NSMenuItem.separator()
    private var modeItems: [PenSyncMode: NSMenuItem] = [:]
    private let intervalRoot = NSMenuItem(title: "Sync Interval", action: nil, keyEquivalent: "")
    private let intervalMenu = NSMenu()
    private var intervalItems: [PenSyncInterval: NSMenuItem] = [:]
    private let commandsSeparator = NSMenuItem.separator()
    private let syncNowItem = NSMenuItem()
    private let cancelSeparator = NSMenuItem.separator()
    private let cancelItem = NSMenuItem()
    private let choiceSeparator = NSMenuItem.separator()
    private let choiceHeaderItem = NSMenuItem()
    private let retrySeparator = NSMenuItem.separator()
    private let retryItem = NSMenuItem()
    private let detailsSeparator = NSMenuItem.separator()
    private let detailsItem = NSMenuItem()
    private let quitSeparator = NSMenuItem.separator()
    private let quitItem = NSMenuItem()

    /// The pen-choice items, rebuilt only when the candidates change.
    private var penItems: [(peripheral: PenPeripheral, item: NSMenuItem)] = []

    /// Whether the menu is currently open and tracking.
    private var isTracking = false

    /// Refreshes the elapsed-time status line while a completed read is shown.
    private var elapsedTimer: Timer?

    /// Creates the status item and installs its menu.
    ///
    /// - Parameters:
    ///   - controller: The state the menu presents.
    ///   - coordinator: The schedule the **Sync Now** command asks for a read.
    ///   - activation: The helper that brings the accessory app forward when the
    ///     details window is opened from the menu.
    init(
        controller: PenSyncController,
        coordinator: PenSyncCoordinator,
        activation: PenSyncActivation
    ) {
        self.controller = controller
        self.coordinator = coordinator
        self.activation = activation
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        buildMenu()
        refresh()
        observeController()
    }

    // MARK: - Status item

    private func configureStatusItem() {
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "pencil.tip",
                accessibilityDescription: PenSyncMenuLabel.accessibilityDescription
            )
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel(PenSyncMenuLabel.accessibilityDescription)
        }
        statusItem.menu = menu
    }

    // MARK: - Menu construction

    private func buildMenu() {
        // AppKit must not re-enable an item on its own: availability is the
        // controller's decision, mirrored onto each item here.
        menu.autoenablesItems = false
        menu.delegate = self
        intervalMenu.autoenablesItems = false

        // The status line is disabled text, not a command.
        statusCell.isEnabled = false
        menu.addItem(statusCell)

        menu.addItem(modesSeparator)
        for mode in PenSyncMode.allCases {
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(chooseMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode
            menu.addItem(item)
            modeItems[mode] = item
        }

        for interval in PenSyncInterval.allCases {
            let item = NSMenuItem(
                title: interval.title,
                action: #selector(chooseInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = interval
            intervalMenu.addItem(item)
            intervalItems[interval] = item
        }
        intervalRoot.submenu = intervalMenu
        menu.addItem(intervalRoot)

        // One read, now, without waiting for discovery or the interval. The command is
        // offered in every saved mode — Pause stops the schedule, not the user — and it
        // is disabled while a read or a pen choice is in progress, because a request can
        // only ever start the read that is not already running. The schedule owns the
        // decision, so the request goes to the coordinator rather than to the controller,
        // which is what keeps the radio handed off once.
        menu.addItem(commandsSeparator)
        syncNowItem.title = "Sync Now"
        syncNowItem.target = self
        syncNowItem.action = #selector(performSyncNow)
        menu.addItem(syncNowItem)

        cancelItem.title = "Cancel Read"
        cancelItem.target = self
        cancelItem.action = #selector(performCancel)
        menu.addItem(cancelSeparator)
        menu.addItem(cancelItem)

        choiceHeaderItem.title = "Choose a pen"
        choiceHeaderItem.isEnabled = false
        menu.addItem(choiceSeparator)
        menu.addItem(choiceHeaderItem)

        retryItem.title = PenSyncController.retryExportActionTitle
        retryItem.target = self
        retryItem.action = #selector(performRetryExport)
        menu.addItem(retrySeparator)
        menu.addItem(retryItem)

        detailsItem.title = "Connection Details…"
        detailsItem.target = self
        detailsItem.action = #selector(openDetailsWindow)
        menu.addItem(detailsSeparator)
        menu.addItem(detailsItem)

        quitItem.title = "Quit NeoBridge"
        quitItem.target = self
        quitItem.action = #selector(quit)
        menu.addItem(quitSeparator)
        menu.addItem(quitItem)
    }

    // MARK: - Presentation

    /// Mirrors the controller's current state onto the menu items.
    ///
    /// Every fixed item keeps its identity and only its title, checkmark, availability,
    /// or visibility changes, so a menu that is open while a read changes state updates
    /// in place rather than being rebuilt around the highlight.
    func refresh() {
        let presentation = PenSyncMenuPresentation.make(from: controller, at: Date())

        statusCell.title = presentation.status
        for entry in presentation.modes {
            modeItems[entry.mode]?.state = entry.isSelected ? .on : .off
        }
        for entry in presentation.intervals {
            intervalItems[entry.interval]?.state = entry.isSelected ? .on : .off
        }

        syncNowItem.isEnabled = presentation.isSyncNowEnabled
        cancelSeparator.isHidden = !presentation.isCancelVisible
        cancelItem.isHidden = !presentation.isCancelVisible
        choiceSeparator.isHidden = !presentation.isChoosingPen
        choiceHeaderItem.isHidden = !presentation.isChoosingPen
        retrySeparator.isHidden = !presentation.isRetryExportVisible
        retryItem.isHidden = !presentation.isRetryExportVisible

        updatePenItems(presentation.pens)
        updateElapsedTimer()
    }

    /// Rebuilds the pen-choice items only when the candidates changed.
    ///
    /// The candidates are the one part of the menu whose count changes, so they are the
    /// one part that is rebuilt rather than updated in place. A rebuild only happens
    /// while the app is asking which pen to use, a moment the user is already looking at
    /// the menu.
    private func updatePenItems(_ pens: [PenSyncMenuPresentation.PenItem]) {
        guard pens.map(\.peripheral) != penItems.map(\.peripheral) else { return }

        for entry in penItems { menu.removeItem(entry.item) }
        penItems.removeAll()

        let anchor = menu.index(of: choiceHeaderItem)
        guard anchor >= 0 else { return }
        for (offset, pen) in pens.enumerated() {
            let item = NSMenuItem(
                title: pen.label,
                action: #selector(choosePen(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = pen.peripheral
            menu.insertItem(item, at: anchor + 1 + offset)
            penItems.append((pen.peripheral, item))
        }
    }

    /// Keeps the elapsed-time label current while a completed read is shown and the menu
    /// is open.
    ///
    /// The label is the only part of the menu that changes without a state change, so a
    /// bounded one-second refresh runs only for that case and only while the menu is
    /// tracking. Every other refresh is driven by a controller change.
    private func updateElapsedTimer() {
        let shouldRun: Bool
        if case .synced = controller.menuStatus, isTracking {
            shouldRun = true
        } else {
            shouldRun = false
        }

        guard shouldRun else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            return
        }
        guard elapsedTimer == nil else { return }

        // `.common` includes the event-tracking mode the open menu runs in, so the label
        // refreshes while the menu is open rather than only after it closes.
        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(elapsedTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    // MARK: - Observation

    /// Refreshes the menu whenever the controller's presented state changes.
    ///
    /// Observation tracking fires once, so each change re-arms it. The refresh is
    /// deferred a turn so it reads the value that was just written rather than the one
    /// being replaced.
    private func observeController() {
        withObservationTracking {
            _ = controller.phase
            _ = controller.syncMode
            _ = controller.syncInterval
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observeController()
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isTracking = true
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        isTracking = false
        updateElapsedTimer()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    // MARK: - Commands

    @objc private func elapsedTick() {
        refresh()
    }

    /// Saves the mode the user selected.
    ///
    /// Clicking the selected mode clears its checkmark, which is not a setting the app
    /// has, so the clear is ignored: the three modes are one choice, and only selecting
    /// a different one changes it.
    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? PenSyncMode else { return }
        guard sender.state != .on else { return }
        controller.selectSyncMode(mode)
    }

    /// Saves the interval the user selected, ignoring a clear of the selected one.
    @objc private func chooseInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? PenSyncInterval else { return }
        guard sender.state != .on else { return }
        controller.selectSyncInterval(interval)
    }

    /// Asks the schedule for one read now.
    @objc private func performSyncNow() {
        coordinator.requestImmediateRead()
    }

    /// Stops the read in flight.
    @objc private func performCancel() {
        controller.cancel()
    }

    /// Reads the pen the user chose.
    @objc private func choosePen(_ sender: NSMenuItem) {
        guard let pen = sender.representedObject as? PenPeripheral else { return }
        controller.choosePen(pen)
    }

    /// Republishes the last stored read's files.
    @objc private func performRetryExport() {
        controller.retryExport()
    }

    /// Opens the details window and brings the app forward.
    ///
    /// Opening a window does not activate an accessory app, so without the activation
    /// the window is created behind the frontmost app and the command looks like it did
    /// nothing. The window makes itself key, and the activation takes focus and is
    /// re-asked as the menu dismissal and any Dock restore settle.
    @objc private func openDetailsWindow() {
        PenSyncWindowBridge.shared.openWindow?(PenSyncScene.windowID)
        activation.activateForCommand()
    }

    /// Quits the app.
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

/// Names the status item for accessibility.
enum PenSyncMenuLabel {
    /// The accessibility description of the status item and its image.
    static let accessibilityDescription = "NeoBridge"
}
