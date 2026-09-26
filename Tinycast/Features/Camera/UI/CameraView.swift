import SwiftUI

struct CameraView: View {
    let coordinator: CameraCoordinator

    var body: some View {
        VStack(spacing: 0) {
            CameraStage(feed: coordinator.feed, mirrored: coordinator.mirrored)
                .frame(width: Theme.Size.cameraStage.width, height: Theme.Size.cameraStage.height)
                .clipShape(
                    RoundedRectangle(cornerRadius: Theme.Radius.cameraPreview, style: .continuous))
                .padding(.horizontal, Theme.Size.cameraCommandInset)
                .padding(.top, Theme.Size.cameraCommandInset)
            CameraActionBar(
                isLive: isLive,
                actionsMenuOpen: coordinator.actionsMenuOpen,
                onTakePhoto: coordinator.takePhoto,
                onToggleActions: coordinator.toggleActionsMenu
            )
            .frame(height: Theme.Size.cameraCommandBarHeight)
        }
        .frame(
            width: Theme.Size.cameraCommandPanelWidth,
            height: Theme.Size.cameraCommandPanelHeight)
        .background(Theme.Colors.panelScrim)
        .background(VisualEffectView())
        .overlay(alignment: .bottomTrailing) {
            if coordinator.actionsMenuOpen {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { coordinator.dismissActionsMenu() }
                        .accessibilityHidden(true)
                    CameraActionsMenu(
                        coordinator: coordinator,
                        onDismiss: coordinator.dismissActionsMenu
                    )
                    .padding(.trailing, Theme.Size.cameraCommandInset)
                    .padding(.bottom, Theme.Size.cameraCommandBarHeight + Theme.Spacing.md)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cameraPanel, style: .continuous))
        .panelEntrance()
    }

    private var isLive: Bool {
        if case .live = coordinator.feed { return true }
        return false
    }
}
