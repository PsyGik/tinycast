import SwiftUI

struct SectionHeader: View {
    enum Style {
        case standard
        case palette
    }

    @Environment(\.metrics) private var metrics
    let title: String
    /// The first header hugs the top; later ones get spacing above, reading as below.
    var isFirst = false
    var configure: (() -> Void)?
    var configureHelp = String(localized: "Configure…")
    var style: Style = .standard

    private var font: Font {
        if style == .palette { return metrics.typography.paletteSectionHeader }
        return metrics.typography.sectionHeader
    }

    private var sectionSpacing: CGFloat {
        style == .palette ? metrics.spacing.paletteSectionSpacing : metrics.spacing.sectionSpacing
    }

    var body: some View {
        HStack(spacing: metrics.spacing.sm) {
            Text(title)
                .lineLimit(1)
            if let configure {
                Button(action: configure) {
                    Image(systemName: "gearshape")
                        .imageScale(.small)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(configureHelp)
            }
            Spacer(minLength: 0)
        }
        .font(font)
        .foregroundStyle(.secondary)
        .padding(.horizontal, metrics.spacing.md)
        .padding(.top, isFirst ? metrics.spacing.xs : sectionSpacing)
        .padding(.bottom, metrics.spacing.sectionHeaderBottom)
    }
}
