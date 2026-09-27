import AppKit
import SwiftUI

@MainActor
final class ResourceWidgetsPanelController: NSObject, NSWindowDelegate {
    private unowned let coordinator: ResourceWidgetsCoordinator
    private var panel: ResourceWidgetsPanel?

    init(coordinator: ResourceWidgetsCoordinator) {
        self.coordinator = coordinator
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(metrics: InterfaceMetrics) {
        let panel = ensurePanel(metrics: metrics)
        panel.cancelFade()
        guard !panel.isVisible else {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            return
        }
        panel.centerOnCursorScreen()
        panel.fadeIn(duration: Theme.Duration.enter) {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
    }

    func close() {
        guard let closing = panel else { return }
        panel = nil
        closing.delegate = nil
        closing.onEscape = nil
        closing.fadeOut(duration: Theme.Duration.exit)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        coordinator.close()
    }

    private func ensurePanel(metrics: InterfaceMetrics) -> ResourceWidgetsPanel {
        if let panel { return panel }
        let hosting = NSHostingView(
            rootView: ResourceWidgetsView()
                .environment(coordinator)
                .environment(\.metrics, metrics))
        hosting.sizingOptions = []
        hosting.setFrameSize(metrics.size.resourceWidgetsPanel)
        let panel = ResourceWidgetsPanel(content: hosting, size: metrics.size.resourceWidgetsPanel)
        panel.delegate = self
        panel.onEscape = { [weak coordinator] in coordinator?.close() }
        self.panel = panel
        return panel
    }
}
