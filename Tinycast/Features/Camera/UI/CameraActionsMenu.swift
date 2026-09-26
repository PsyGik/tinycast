import SwiftUI

struct CameraActionsMenu: View {
    let coordinator: CameraCoordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        PopoverMenu(
            header: "Camera",
            items: coordinator.filteredActionsMenuItems,
            selection: $coordinator.actionsMenuSelection,
            width: Theme.Size.cameraActionsMenuWidth,
            onActivate: { coordinator.activateActionsMenuItem(at: $0) },
            search: PopoverMenu.Search(placeholder: "Search Actions", placement: .top)
        )
        .environment(coordinator.actionsMenuPaletteState)
        .onChange(of: coordinator.actionsMenuPaletteState.menuQuery) {
            coordinator.resetActionsMenuSelection()
        }
    }
}
