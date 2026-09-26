import SwiftUI

/// A lens iris over the stage: it idles nearly shut while the camera warms up, then opens on it.
struct ApertureReveal<Content: View>: View {
    let settled: Bool
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var opened = false
    @State private var finished = false

    var body: some View {
        content
            .overlay {
                if !finished, !reduceMotion {
                    ZStack {
                        Iris(openness: openness, turn: turn)
                            .fill(Theme.Colors.apertureBlade, style: FillStyle(eoFill: true))
                        IrisSeams(openness: openness, turn: turn)
                            .stroke(Theme.Colors.apertureSeam, lineWidth: 1)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .onAppear {
                guard !settled else {
                    finished = true
                    return
                }
                withAnimation(
                    .easeInOut(duration: Theme.Duration.apertureBreath).repeatForever(autoreverses: true)
                ) { breathing = true }
            }
            .onChange(of: settled) { _, settled in
                guard settled, !opened else { return }
                withAnimation(.easeInOut(duration: Theme.Duration.apertureOpen)) {
                    opened = true
                } completion: {
                    finished = true
                }
            }
    }

    private var openness: CGFloat { opened ? 1 : (breathing ? 0.16 : 0.08) }
    private var turn: CGFloat { opened ? 0 : (breathing ? -.pi / 18 : .pi / 18) }
}

/// Where the six blade tips sit; at `openness` 1 the hexagon's inner circle clears every corner.
private enum IrisGeometry {
    static func vertices(in rect: CGRect, openness: CGFloat, turn: CGFloat) -> [CGPoint] {
        let reach = hypot(rect.width, rect.height) / 2 / cos(.pi / 6)
        let radius = max(openness, 0) * reach
        return (0..<6).map { index in
            let angle = turn + CGFloat(index) * .pi / 3
            return CGPoint(x: rect.midX + radius * cos(angle), y: rect.midY + radius * sin(angle))
        }
    }

    static func reach(of rect: CGRect) -> CGFloat {
        hypot(rect.width, rect.height)
    }
}

/// The blades: the whole stage less the hexagonal opening, filled even-odd.
private struct Iris: Shape {
    var openness: CGFloat
    var turn: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(openness, turn) }
        set {
            openness = newValue.first
            turn = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addLines(IrisGeometry.vertices(in: rect, openness: openness, turn: turn))
        path.closeSubpath()
        return path
    }
}

/// Each blade's leading edge, carried on from the opening out past the stage's edge.
private struct IrisSeams: Shape {
    var openness: CGFloat
    var turn: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(openness, turn) }
        set {
            openness = newValue.first
            turn = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let tips = IrisGeometry.vertices(in: rect, openness: openness, turn: turn)
        var path = Path()
        for index in tips.indices {
            let tip = tips[index]
            let previous = tips[(index + tips.count - 1) % tips.count]
            let dx = tip.x - previous.x
            let dy = tip.y - previous.y
            let length = hypot(dx, dy)
            guard length > 0.5 else { continue }
            let reach = IrisGeometry.reach(of: rect)
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x + dx / length * reach, y: tip.y + dy / length * reach))
        }
        return path
    }
}
