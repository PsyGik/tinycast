import SwiftUI

/// The launcher footer's live readings; it alone reads the sampler, so a tick redraws only these.
struct ResourcePills: View {
    @Environment(ResourceWidgetsCoordinator.self) private var resources
    @Environment(\.metrics) private var metrics

    var body: some View {
        let snapshot = resources.snapshot
        HStack(spacing: metrics.spacing.xs) {
            pill("cpu", ResourceReadout.percent(snapshot?.cpuUtilization))
                .help("CPU in use")
            pill("memorychip", ResourceReadout.percent(snapshot?.memory?.usedPercentage))
                .help(memoryHelp(snapshot?.memory))
            pill(
                "network",
                "↓\(ResourceReadout.rate(snapshot?.network?.receiveBytesPerSecond)) "
                    + "↑\(ResourceReadout.rate(snapshot?.network?.transmitBytesPerSecond))"
            )
            .help("Network download and upload")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("System stats")
    }

    /// Shaped like a filled footer keycap, so the pills read as part of the same bar.
    private func pill(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: metrics.spacing.xs) {
            SymbolImage(name: symbol, size: metrics.size.resourcePillGlyph, monochrome: true)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(metrics.typography.rowTrailing)
        .foregroundStyle(Theme.Colors.textSecondary)
        .padding(.horizontal, metrics.spacing.sm)
        .frame(height: metrics.size.footerKeyCapHeight)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.keyCap, style: .continuous)
                .fill(Theme.Colors.controlSurface)
        )
        .fixedSize()
    }

    private func memoryHelp(_ memory: ResourceMemoryUsage?) -> String {
        guard let memory else { return "Memory in use" }
        return "Memory in use: \(ResourceReadout.gigabytes(memory.usedBytes)) of "
            + ResourceReadout.gigabytes(memory.totalBytes)
    }
}
