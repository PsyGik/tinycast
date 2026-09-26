import SwiftUI

struct CameraActionsMenu: View {
    let coordinator: CameraCoordinator
    let onDismiss: () -> Void

    @State private var selection = 0
    @State private var menuState = PaletteState()

    var body: some View {
        let menu = content
        let items = filteredItems(from: menu.items)
        PopoverMenu(
            header: menu.header,
            items: items,
            selection: $selection,
            width: Theme.Size.cameraActionsMenuWidth,
            onActivate: activate,
            search: PopoverMenu.Search(placeholder: "Search Actions", placement: .top)
        )
        .environment(menuState)
        .onAppear {
            menuState.menuQuery = ""
            menuState.noteMenuPresentation()
            selection = 0
        }
        .onChange(of: menuState.menuQuery) { selection = 0 }
    }

    private var filteredItems: [PopoverMenuItem] { filteredItems(from: content.items) }

    private func filteredItems(from items: [PopoverMenuItem]) -> [PopoverMenuItem] {
        let query = menuState.menuQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var content: PopoverMenuContent {
        var items = [
            PopoverMenuItem(
                title: "Take Photo", systemImage: "camera", isEnabled: isLive,
                shortcut: "↵", action: coordinator.takePhoto),
            PopoverMenuItem(
                title: "Mirror",
                icon: coordinator.mirrored ? .symbol("checkmark") : .blank,
                isEnabled: isLive,
                action: { coordinator.mirrored.toggle() })
        ]
        if coordinator.canSwitchCamera {
            items.append(
                PopoverMenuItem(
                    title: "Switch Camera", systemImage: "camera.rotate",
                    action: coordinator.switchCamera))
        }
        items.append(
            PopoverMenuItem(
                title: "Close", systemImage: "xmark", startsSection: true,
                shortcut: "⎋", action: coordinator.close))
        return PopoverMenuContent(header: "Camera", items: items)
    }

    private var isLive: Bool {
        if case .live = coordinator.feed { return true }
        return false
    }

    private func activate(_ index: Int) {
        guard filteredItems.indices.contains(index) else { return }
        let item = filteredItems[index]
        guard item.isSelectable else { return }
        onDismiss()
        item.action()
    }
}
