import AppKit
import SwiftUI

/// Owns the standalone camera surface: one panel at a time, and the camera stops with it.
@MainActor
@Observable
final class CameraCoordinator: NSObject, NSWindowDelegate {
    private(set) var feed: CameraSession.Feed = .noCamera
    private(set) var canSwitchCamera = false
    private(set) var actionsMenuOpen = false
    var actionsMenuSelection = 0
    /// Remembered for the launch, so reopening the command keeps the framing you were happy with.
    var mirrored = true

    @ObservationIgnored private let session = CameraSession(.capture)
    @ObservationIgnored let actionsMenuPaletteState = PaletteState()
    @ObservationIgnored private unowned let core: AppCore
    @ObservationIgnored private var panel: CameraPanel?
    /// Held across the camera warm-up too, so a chord repeating into it cannot stack panels.
    @ObservationIgnored private var opening = false

    init(core: AppCore) {
        self.core = core
    }

    /// The camera settles first: a panel over a starting session shows a black stage.
    func show() async {
        guard !opening, panel == nil else { return }
        opening = true
        defer { opening = false }
        actionsMenuOpen = false
        feed = await session.start()
        canSwitchCamera = session.hasMultipleDevices
        present()
    }

    func close() {
        guard let closing = panel else { return }
        actionsMenuOpen = false
        panel = nil
        closing.delegate = nil
        closing.onKey = nil
        closing.onActions = nil
        closing.onActionsMenuKey = nil
        // The camera goes with the panel, not before it: tearing it down mid-fade blanks the feed.
        closing.fadeOut(duration: Theme.Duration.exit) { [weak self] in
            // Unless a panel raised inside the fade already owns the camera.
            guard let self, !opening else { return }
            session.stop()
        }
    }

    func toggleActionsMenu() {
        guard actionsMenuOpen else {
            actionsMenuPaletteState.menuQuery = ""
            actionsMenuPaletteState.noteMenuPresentation()
            resetActionsMenuSelection()
            actionsMenuOpen = true
            return
        }
        dismissActionsMenu()
    }

    func dismissActionsMenu() {
        actionsMenuOpen = false
    }

    var filteredActionsMenuItems: [PopoverMenuItem] {
        let query = actionsMenuPaletteState.menuQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return actionsMenuItems }
        return actionsMenuItems.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    func resetActionsMenuSelection() {
        actionsMenuSelection = filteredActionsMenuItems.firstIndex(where: \.isSelectable) ?? 0
    }

    func moveActionsMenuSelection(by delta: Int) {
        let items = filteredActionsMenuItems
        var index = actionsMenuSelection + delta
        while items.indices.contains(index) {
            if items[index].isSelectable {
                actionsMenuSelection = index
                return
            }
            index += delta
        }
    }

    func activateActionsMenuSelection() {
        activateActionsMenuItem(at: actionsMenuSelection)
    }

    func activateActionsMenuItem(at index: Int) {
        let items = filteredActionsMenuItems
        guard items.indices.contains(index) else { return }
        let item = items[index]
        guard item.isSelectable else { return }
        dismissActionsMenu()
        item.action()
    }

    func handleActionsMenuKey(_ key: CameraPanel.ActionsMenuKey) -> Bool {
        guard actionsMenuOpen else { return false }
        switch key {
        case .up:
            moveActionsMenuSelection(by: -1)
        case .down:
            moveActionsMenuSelection(by: 1)
        case .primary:
            activateActionsMenuSelection()
        case .cancel:
            if actionsMenuPaletteState.menuQuery.isEmpty {
                dismissActionsMenu()
            } else {
                actionsMenuPaletteState.menuQuery = ""
            }
        }
        return true
    }

    func switchCamera() {
        Task { await session.switchToNextDevice() }
    }

    /// The panel goes with the shot: the command is done, and the camera light goes out with it.
    func takePhoto() {
        guard case .live = feed else { return }
        actionsMenuOpen = false
        let mirrored = mirrored
        Task {
            let png = await session.capturePhoto(mirrored: mirrored)
            close()
            guard let png else {
                core.showMessage("Couldn't take the photo", tone: .danger)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
            core.showMessage("Photo copied")
        }
    }

    private func present() {
        let hosting = NSHostingView(rootView: CameraView(coordinator: self))
        hosting.setFrameSize(hosting.fittingSize)
        let panel = CameraPanel(content: hosting)
        panel.delegate = self
        panel.onKey = { [weak self] key in
            guard let self else { return }
            if key == .primary { takePhoto() } else { close() }
        }
        panel.onActions = { [weak self] in self?.toggleActionsMenu() }
        panel.onActionsMenuKey = { [weak self] key in
            self?.handleActionsMenuKey(key) ?? false
        }
        self.panel = panel
        panel.centerOnCursorScreen()
        // Non-activating like the palette: key focus without pulling the user out of their app.
        panel.fadeIn(duration: Theme.Duration.enter) {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
    }

    // MARK: - NSWindowDelegate

    /// Click-away closes rather than leaving a camera running behind another window.
    func windowDidResignKey(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        close()
    }

    private var actionsMenuItems: [PopoverMenuItem] {
        let isLive: Bool
        if case .live = feed {
            isLive = true
        } else {
            isLive = false
        }

        var items = [
            PopoverMenuItem(
                title: "Take Photo", systemImage: "camera", isEnabled: isLive,
                shortcut: "↵", action: takePhoto),
            PopoverMenuItem(
                title: "Mirror",
                icon: mirrored ? .symbol("checkmark") : .blank,
                isEnabled: isLive,
                action: { self.mirrored.toggle() })
        ]
        if canSwitchCamera {
            items.append(
                PopoverMenuItem(
                    title: "Switch Camera", systemImage: "camera.rotate",
                    action: switchCamera))
        }
        items.append(
            PopoverMenuItem(
                title: "Close", systemImage: "xmark", startsSection: true,
                shortcut: "⎋", action: close))
        return items
    }
}
