import SwiftUI

struct CameraActionBar: View {
    let isLive: Bool
    let actionsMenuOpen: Bool
    let onTakePhoto: () -> Void
    let onToggleActions: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: Theme.Size.hairline)
                .accessibilityHidden(true)
            HStack(spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.sm) {
                    SymbolImage(name: "camera", size: Theme.Size.menuIcon)
                    Text("Camera")
                        .font(Theme.Typography.bar)
                }
                .foregroundStyle(Theme.Colors.textSecondary)
                .accessibilityElement(children: .combine)

                Spacer(minLength: Theme.Spacing.md)

                HStack(spacing: Theme.Spacing.sm) {
                    BarButton(action: onTakePhoto) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text("Take Photo")
                                .font(Theme.Typography.bar)
                            KeyCapChip(text: "↵")
                        }
                        .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .disabled(!isLive)
                    .opacity(isLive ? 1 : 0.45)
                    .accessibilityLabel("Take Photo")

                    Rectangle()
                        .fill(Theme.Colors.separator)
                        .frame(width: Theme.Size.hairline, height: Theme.Size.keyCap)
                        .accessibilityHidden(true)

                    BarButton(isSelected: actionsMenuOpen, action: onToggleActions) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text("Actions")
                                .font(Theme.Typography.bar)
                            KeyCapChip(text: "⌘K")
                        }
                        .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .accessibilityLabel("Actions")
                    .accessibilityValue(actionsMenuOpen ? "Open" : "Closed")
                }
            }
            .padding(.horizontal, Theme.Size.cameraCommandInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Colors.cardFill)
    }
}
