import SwiftUI

struct ResourceWidgetsView: View {
    @Environment(ResourceWidgetsCoordinator.self) private var coordinator
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.lg) {
            header
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: metrics.spacing.md) {
                cpuCard
                memoryCard
                networkCard
                gpuCard
            }
        }
        .padding(metrics.spacing.xxl)
        .frame(
            width: metrics.size.resourceWidgetsPanel.width,
            height: metrics.size.resourceWidgetsPanel.height)
        .background(Theme.Colors.panelScrim)
        .background(GlassEffectView())
        .clipShape(RoundedRectangle(cornerRadius: metrics.radius.panel, style: .continuous))
        .panelEntrance()
    }

    private var header: some View {
        HStack(spacing: metrics.spacing.md) {
            Image(systemName: CommandID.resourceWidgets.sfSymbol)
                .font(metrics.typography.headerIcon)
                .foregroundStyle(Theme.Colors.textSecondary)
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text("Resource Widgets")
                    .font(metrics.typography.panelTitle)
                Text("Live while this panel is open")
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer(minLength: metrics.spacing.md)
            Button(action: coordinator.close) {
                Image(systemName: "xmark")
                    .font(metrics.typography.rowTrailing.weight(.semibold))
                    .frame(width: metrics.size.menuButton, height: metrics.size.menuButton)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.textSecondary)
            .accessibilityLabel("Close Resource Widgets")
        }
        .accessibilityElement(children: .contain)
    }

    private var cpuCard: some View {
        let value = coordinator.snapshot?.cpuUtilization.map { "\(($0 * 100).rounded())%" } ?? "—"
        return ResourceWidgetCard(
            title: "CPU",
            symbol: "cpu",
            value: value,
            detail: "Whole-system utilization",
            accessibilityValue: coordinator.snapshot?.cpuUtilization.map {
                "\(Int(($0 * 100).rounded())) percent"
            } ?? "Waiting for a second sample",
            values: coordinator.history.samples.compactMap(\.cpuUtilization),
            color: .blue)
    }

    private var memoryCard: some View {
        let memory = coordinator.snapshot?.memory
        let value = memory.map { "\(Int(($0.usedPercentage * 100).rounded()))%" } ?? "—"
        let detail = memory.map {
            let used = ByteCountFormatter.string(
                fromByteCount: Int64($0.usedBytes), countStyle: .memory)
            let total = ByteCountFormatter.string(
                fromByteCount: Int64($0.totalBytes), countStyle: .memory)
            let compressed = ByteCountFormatter.string(
                fromByteCount: Int64($0.compressedBytes), countStyle: .memory)
            let swap = $0.swapUsedBytes.map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
            } ?? "Unavailable"
            return "\(used) of \(total)\nCompressed \(compressed) • Swap \(swap)"
        } ?? "Memory unavailable"
        return ResourceWidgetCard(
            title: "Memory",
            symbol: "memorychip",
            value: value,
            detail: detail,
            accessibilityValue: memory.map {
                "\(Int(($0.usedPercentage * 100).rounded())) percent used, \(detail)"
            } ?? "Unavailable",
            values: coordinator.history.samples.compactMap { $0.memory?.usedPercentage },
            color: .orange)
    }

    private var networkCard: some View {
        let network = coordinator.snapshot?.network
        let value = network.map {
            "↓ \(Self.rate($0.receiveBytesPerSecond))  "
                + "↑ \(Self.rate($0.transmitBytesPerSecond))"
        } ?? "—"
        return ResourceWidgetCard(
            title: "Network",
            symbol: "network",
            value: value,
            detail: "Aggregate active interfaces",
            accessibilityValue: network.map {
                "Receive \(Self.rate($0.receiveBytesPerSecond)), transmit "
                    + "\(Self.rate($0.transmitBytesPerSecond)) per second"
            } ?? "Waiting for a second sample",
            values: coordinator.history.samples.compactMap {
                guard let network = $0.network else { return nil }
                return network.receiveBytesPerSecond + network.transmitBytesPerSecond
            },
            color: .green)
    }

    private var gpuCard: some View {
        ResourceWidgetCard(
            title: "GPU",
            symbol: "square.3.layers.3d",
            value: "Unavailable",
            detail: "No supported public system API",
            accessibilityValue: "GPU utilization unavailable",
            values: [],
            color: .gray)
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .binary) + "/s"
    }
}

private struct ResourceWidgetCard: View {
    @Environment(\.metrics) private var metrics

    let title: String
    let symbol: String
    let value: String
    let detail: String
    let accessibilityValue: String
    let values: [Double]
    let color: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            HStack(spacing: metrics.spacing.xs) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(title)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Text(value)
                .font(metrics.typography.panelTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(2)
            if !values.isEmpty {
                ResourceSparkline(values: values, color: color)
                    .frame(height: metrics.size.resourceWidgetsSparklineHeight)
            } else {
                Spacer(minLength: metrics.size.resourceWidgetsSparklineHeight)
            }
        }
        .padding(metrics.spacing.lg)
        .frame(
            maxWidth: .infinity,
            minHeight: metrics.size.resourceWidgetsCardHeight,
            alignment: .topLeading)
        .background(shape.fill(Theme.Colors.cardFill))
        .overlay(shape.strokeBorder(Theme.Colors.cardStroke))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }
}

private struct ResourceSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard let first = values.first else { return }
                let lower = values.min() ?? first
                let upper = values.max() ?? first
                let span = max(upper - lower, 0.0001)
                let step = values.count == 1
                    ? geometry.size.width
                    : geometry.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * step
                    let y = geometry.size.height * (1 - CGFloat((value - lower) / span))
                    let point = CGPoint(x: x, y: y)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
