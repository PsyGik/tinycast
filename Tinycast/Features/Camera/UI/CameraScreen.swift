import SwiftUI

struct CameraScreen: PaletteScreen {
    struct Row: Identifiable { let id = 0 }
    let coordinator: CameraCoordinator
    let goBack: () -> Void

    var rows: [Row] { [] }
    var primaryActionTitle: String { "Take Photo" }
    var hidesSearchField: Bool { true }
    var actsWithoutRows: Bool { true }

    func actions(at selection: Int) -> PopoverMenuContent? {
        let live: Bool
        if case .live = coordinator.feed { live = true } else { live = false }
        var items = [
            PopoverMenuItem(title: "Take Photo", systemImage: "camera", isEnabled: live,
                            shortcut: "↵", action: coordinator.takePhoto),
            PopoverMenuItem(title: "Mirror", icon: coordinator.mirrored ? .symbol("checkmark") : .blank,
                            isEnabled: live, action: { coordinator.mirrored.toggle() })
        ]
        if coordinator.canSwitchCamera {
            items.append(PopoverMenuItem(title: "Switch Camera", systemImage: "camera.rotate",
                                         action: coordinator.switchCamera))
        }
        items.append(PopoverMenuItem(title: "Back to Search", systemImage: "arrow.left",
                                     startsSection: true, shortcut: "⎋", action: goBack))
        return PopoverMenuContent(header: "Camera", items: items)
    }

    func activate(at selection: Int) { coordinator.takePhoto() }

    func secondary(at selection: Int) -> Bool { false }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(
            ApertureReveal(settled: coordinator.feed != nil) {
                CameraStage(feed: coordinator.feed, mirrored: coordinator.mirrored)
            }
                .overlay(alignment: .topLeading) {
                    Button(action: goBack) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                    .accessibilityLabel("Back to Search")
                }
                .onDisappear { coordinator.stop() })
    }
}
