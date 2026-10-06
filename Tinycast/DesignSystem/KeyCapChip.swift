import SwiftUI

/// A single keycap chip: `.outline` for hotkey hints on rows, `.filled` for footer shortcuts.
struct KeyCapChip: View {
    struct Label: View {
        let text: String
        var prefix: String?
        var spacing: CGFloat = Theme.Spacing.xxs

        var body: some View {
            if let prefix {
                HStack(spacing: spacing) {
                    Text(prefix).textScale(.secondary)
                    Text(text)
                }
            } else {
                Text(text)
            }
        }
    }

    enum Style {
        case outline
        case filled
    }

    /// Sanctioned cap sizes, so a bigger or smaller one is a named choice, not a stray frame.
    enum Scale {
        case compact
        case standard
        case footer
        case hero

        func size(_ metrics: InterfaceMetrics) -> CGSize {
            switch self {
            case .compact:
                CGSize(width: metrics.size.compactKeyCap, height: metrics.size.compactKeyCap)
            case .standard:
                CGSize(width: metrics.size.keyCap, height: metrics.size.keyCap)
            case .footer:
                CGSize(
                    width: metrics.size.footerKeyCapWidth,
                    height: metrics.size.footerKeyCapHeight)
            case .hero:
                CGSize(width: metrics.size.heroKeyCap, height: metrics.size.heroKeyCap)
            }
        }

        @MainActor
        func font(_ metrics: InterfaceMetrics) -> Font {
            switch self {
            case .compact: metrics.typography.compactKeyCap
            case .standard: metrics.typography.keyCap
            case .footer: metrics.typography.keyCap
            case .hero: metrics.typography.heroKeyCap
            }
        }
    }

    let text: String
    var style: Style = .filled
    var scale: Scale = .standard
    var prefix: String?
    @Environment(\.metrics) private var metrics

    /// "↵" falls back to another face that seats high, so nudge it render-only.
    private static let returnGlyphDrop: CGFloat = 1.1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.keyCap, style: .continuous)
        let size = scale.size(metrics)
        Label(text: text, prefix: prefix, spacing: metrics.spacing.xxs)
            .font(scale.font(metrics))
            .foregroundStyle(Theme.Colors.textSecondary)
            .offset(y: text == "↵" ? Self.returnGlyphDrop : 0)
            .padding(.horizontal, metrics.spacing.xs)
            .frame(minWidth: size.width, minHeight: size.height)
            .background {
                switch style {
                case .filled: shape.fill(Theme.Colors.controlSurface)
                case .outline: shape.strokeBorder(Theme.Colors.border, lineWidth: 1)
                }
            }
    }
}
