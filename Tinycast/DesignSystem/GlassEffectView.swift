import SwiftUI

/// Native Liquid Glass backdrop for Tinycast's borderless panels.
struct GlassEffectView: NSViewRepresentable {
    let cornerRadius: CGFloat?

    init(cornerRadius: CGFloat? = nil) {
        self.cornerRadius = cornerRadius
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        if let cornerRadius {
            view.cornerRadius = cornerRadius
        }
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        if let cornerRadius {
            nsView.cornerRadius = cornerRadius
        }
    }
}
