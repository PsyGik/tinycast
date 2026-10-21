import SwiftUI

/// The launcher's category pills: All, then each kind the index holds, in section order.
struct LauncherCategoryChips: View {
    let kinds: [AppEntry.Kind]
    let selected: AppEntry.Kind?
    let onSelect: (AppEntry.Kind?) -> Void
    @Environment(\.metrics) private var metrics

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: metrics.spacing.sm) {
                    chip(nil, title: "All", symbol: "rectangle.stack")
                    ForEach(kinds, id: \.self) { kind in
                        chip(
                            kind, title: String(localized: kind.descriptor.sectionTitle),
                            symbol: kind.descriptor.categorySymbol)
                    }
                }
                .padding(.vertical, metrics.spacing.xs)
            }
            .scrollIndicators(.never)
            // Arrow keys step past the visible edge, so the chosen pill always scrolls into view.
            .onChange(of: selected) { _, kind in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.id(kind)) }
            }
        }
    }

    private func chip(_ kind: AppEntry.Kind?, title: String, symbol: String) -> some View {
        CategoryChip(title: title, symbol: symbol, isSelected: kind == selected) { onSelect(kind) }
            .id(Self.id(kind))
    }

    private static func id(_ kind: AppEntry.Kind?) -> String { kind?.rawValue ?? "all" }
}

/// Hover state lives here, so lighting one pill never re-renders the row around it.
private struct CategoryChip: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.metrics) private var metrics

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.categoryChip, style: .continuous)
        Button(action: action) {
            HStack(spacing: metrics.spacing.xs) {
                Image(systemName: symbol)
                    .imageScale(.small)
                Text(title)
                    .lineLimit(1)
            }
            .font(metrics.typography.rowTrailing)
            .foregroundStyle(
                isSelected || hovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
            .padding(.horizontal, metrics.spacing.lg)
            .frame(height: metrics.size.categoryChipHeight)
            .background {
                if isSelected {
                    shape.fill(Theme.Colors.categoryChipSelectedFill)
                        .overlay(shape.strokeBorder(Theme.Colors.categoryChipSelectedStroke))
                } else {
                    shape.fill(hovered ? Theme.Colors.controlHover : Theme.Colors.controlSurface)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
