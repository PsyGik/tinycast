import Foundation

/// The launcher footer's compact readings; a reading not sampled yet shows as a dash.
enum ResourceReadout {
    static let placeholder = "–"

    static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return placeholder }
        return "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    /// Decimal units, as rates are quoted; one decimal only below ten, so the pill barely shifts.
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return placeholder }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits = unit > 0 && value < 9.95 ? String(format: "%.1f", value) : String(Int(value.rounded()))
        return "\(digits) \(units[unit])"
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}

extension ResourceSnapshot {
    /// A restarted sampler's first sample has no deltas yet, so it keeps the last ones it saw.
    func filling(from previous: ResourceSnapshot?) -> ResourceSnapshot {
        ResourceSnapshot(
            timestamp: timestamp,
            cpuUtilization: cpuUtilization ?? previous?.cpuUtilization,
            memory: memory ?? previous?.memory,
            network: network ?? previous?.network,
            gpu: gpu)
    }
}
