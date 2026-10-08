import AppKit
import QuickLookUI

/// The system Quick Look window, for a file worth seeing large: the palette has stepped aside.
@MainActor
final class SystemQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// Every row the palette listed, so the window's own arrows page through them.
    private var items: [URL] = []
    /// The app the palette was summoned over, given focus back when the window closes.
    private var returnTo: NSRunningApplication?

    func show(_ items: [URL], at index: Int, returningTo app: NSRunningApplication?) {
        guard !items.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.items = items
        returnTo = app
        // An accessory app's panel would open behind the frontmost app without this.
        NSApp.activate()
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(index, 0), items.count - 1)
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url = MainActor.assumeIsolated { items.indices.contains(index) ? items[index] : nil }
        return url.map { $0 as NSURL }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            items = []
            returnTo?.activate()
            returnTo = nil
        }
    }
}
