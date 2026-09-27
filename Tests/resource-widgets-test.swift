import Foundation

@main
@MainActor
struct ResourceWidgetsTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func expect(_ actual: Double?, _ expected: Double?, _ message: String) {
        switch (actual, expected) {
        case let (.some(actual), .some(expected)):
            expect(
                abs(actual - expected) < 1e-9,
                "\(message) — got \(actual), want \(expected)")
        case (.none, .none):
            passes += 1
        default:
            failures += 1
            print(
                "FAIL: \(message) — got \(String(describing: actual)), "
                    + "want \(String(describing: expected))")
        }
    }

    static func main() async {
        cpuDeltas()
        cpuFirstSampleAndReset()
        memoryTotals()
        networkAggregation()
        networkExclusionAndReset()
        historyIsBounded()
        gpuIsExplicitlyUnavailable()
        readoutFormatting()
        restartFillsMissingDeltas()
        await samplingLoopStopsWhenCancelled()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    static func readoutFormatting() {
        expect(ResourceReadout.percent(0.123) == "12%", "a fraction reads as a rounded percent")
        expect(ResourceReadout.percent(1.4) == "100%", "a percent never passes 100")
        expect(ResourceReadout.percent(-0.2) == "0%", "a percent never drops below 0")
        expect(ResourceReadout.percent(nil) == "–", "no reading yet shows a dash")
        expect(ResourceReadout.rate(0) == "0 B/s", "an idle link reads in bytes")
        expect(ResourceReadout.rate(512) == "512 B/s", "under a kilobyte stays in bytes")
        expect(ResourceReadout.rate(80_000) == "80 KB/s", "tens of units drop the decimal")
        expect(ResourceReadout.rate(1_234_567) == "1.2 MB/s", "single units keep one decimal")
        expect(ResourceReadout.rate(999_700) == "1.0 MB/s", "a value that rounds to 1000 moves up a unit")
        expect(ResourceReadout.rate(nil) == "–", "no rate yet shows a dash")
        expect(ResourceReadout.rate(.nan) == "–", "a broken rate shows a dash, not NaN")
        expect(
            ResourceReadout.gigabytes(8_200_000_000) == "8.2 GB", "memory totals read in decimal gigabytes")
    }

    static func restartFillsMissingDeltas() {
        let before = ResourceSnapshot(
            timestamp: Date(timeIntervalSince1970: 0), cpuUtilization: 0.4,
            network: ResourceNetworkRates(receiveBytesPerSecond: 10, transmitBytesPerSecond: 5))
        let first = ResourceSnapshot(timestamp: Date(timeIntervalSince1970: 60))
        let filled = first.filling(from: before)
        expect(filled.cpuUtilization == 0.4, "a restart's first sample keeps the last CPU reading")
        expect(filled.network?.receiveBytesPerSecond == 10, "…and the last network rates")
        expect(filled.timestamp == first.timestamp, "…but keeps its own timestamp")
        let fresh = ResourceSnapshot(timestamp: Date(timeIntervalSince1970: 61), cpuUtilization: 0.1)
        expect(fresh.filling(from: before).cpuUtilization == 0.1, "a real reading always wins")
        expect(first.filling(from: nil).cpuUtilization == nil, "with nothing earlier, it stays empty")
    }

    static func cpuDeltas() {
        let previous = ResourceCPUCounters(user: 20, nice: 2, system: 8, idle: 70)
        let current = ResourceCPUCounters(user: 40, nice: 3, system: 17, idle: 90)
        expect(
            ResourceMetrics.cpuUtilization(current: current, previous: previous),
            0.6,
            "CPU utilization uses non-idle counter deltas")
    }

    static func cpuFirstSampleAndReset() {
        let current = ResourceCPUCounters(user: 1, nice: 0, system: 1, idle: 8)
        expect(
            ResourceMetrics.cpuUtilization(current: current, previous: nil) == nil,
            "the first CPU sample does not invent a utilization")

        let previous = ResourceCPUCounters(user: 20, nice: 0, system: 4, idle: 30)
        let reset = ResourceCPUCounters(user: 2, nice: 0, system: 1, idle: 5)
        expect(
            ResourceMetrics.cpuUtilization(current: reset, previous: previous) == nil,
            "a CPU counter reset produces no fabricated utilization")
    }

    static func memoryTotals() {
        let counters = ResourceMemoryCounters(
            totalBytes: 16_000,
            pageSize: 1_000,
            freePages: 2,
            speculativePages: 1,
            purgeablePages: 1,
            compressedPages: 2)
        let memory = ResourceMetrics.memoryUsage(from: counters)
        expect(memory.usedBytes == 12_000, "memory used bytes exclude reclaimable pages")
        expect(memory.totalBytes == 16_000, "memory keeps the physical total")
        expect(memory.compressedBytes == 2_000, "memory reports compressed bytes")
        expect(memory.usedPercentage == 0.75, "memory used percentage is derived from totals")
    }

    static func networkAggregation() {
        let previous = ResourceNetworkCounters(receiveBytes: 100, transmitBytes: 200)
        let current = ResourceNetworkCounters(receiveBytes: 1_100, transmitBytes: 700)
        let rates = ResourceMetrics.networkRates(
            current: current, previous: previous, elapsed: 2)
        expect(rates?.receiveBytesPerSecond == 500, "network receive rates use byte deltas")
        expect(rates?.transmitBytesPerSecond == 250, "network transmit rates use byte deltas")
    }

    static func networkExclusionAndReset() {
        let interfaces = [
            ResourceNetworkInterface(
                isUp: true, isLoopback: false, receiveBytes: 100, transmitBytes: 50),
            ResourceNetworkInterface(
                isUp: false, isLoopback: false, receiveBytes: 9_000, transmitBytes: 9_000),
            ResourceNetworkInterface(
                isUp: true, isLoopback: true, receiveBytes: 8_000, transmitBytes: 8_000),
            ResourceNetworkInterface(
                isUp: true, isLoopback: false, receiveBytes: 300, transmitBytes: 150)
        ]
        expect(
            ResourceNetworkCounters(interfaces: interfaces)
                == ResourceNetworkCounters(receiveBytes: 400, transmitBytes: 200),
            "network aggregation includes only active non-loopback interfaces")

        let previous = ResourceNetworkCounters(receiveBytes: 500, transmitBytes: 500)
        let reset = ResourceNetworkCounters(receiveBytes: 10, transmitBytes: 10)
        expect(
            ResourceMetrics.networkRates(current: reset, previous: nil, elapsed: 1) == nil,
            "the first network sample does not invent a rate")
        expect(
            ResourceMetrics.networkRates(current: reset, previous: previous, elapsed: 1) == nil,
            "a network counter reset produces no fabricated rate")
        expect(
            ResourceMetrics.networkRates(current: reset, previous: previous, elapsed: 0) == nil,
            "a zero sampling interval produces no rate")
    }

    static func historyIsBounded() {
        var history = ResourceHistory(capacity: 3)
        for index in 0..<5 {
            history.append(ResourceSnapshot(timestamp: Date(timeIntervalSince1970: Double(index))))
        }
        expect(history.samples.count == 3, "history keeps its configured bound")
        expect(
            history.samples.map { $0.timestamp.timeIntervalSince1970 } == [2, 3, 4],
            "history drops the oldest samples first")
        history.reset()
        expect(history.samples.isEmpty, "history reset clears all samples")
    }

    static func gpuIsExplicitlyUnavailable() {
        let snapshot = ResourceSnapshot(timestamp: Date(timeIntervalSince1970: 0))
        expect(snapshot.gpu == .unavailable, "GPU state is explicitly unavailable")
        expect(snapshot.gpu.value == nil, "GPU unavailable state has no fabricated value")
    }

    static func samplingLoopStopsWhenCancelled() async {
        let loop = ResourceSamplingLoop(
            readers: .init(
                cpu: StubCPUReader(), memory: StubMemoryReader(), network: StubNetworkReader()),
            clock: ImmediateResourceClock())
        let task = Task {
            await loop.run { _ in }
        }
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()
        await task.value
        expect(task.isCancelled, "sampling loop observes cancellation")
    }
}

private struct StubCPUReader: ResourceCPUReader {
    func read() -> ResourceCPUCounters? {
        ResourceCPUCounters(user: 1, nice: 0, system: 1, idle: 8)
    }
}

private struct StubMemoryReader: ResourceMemoryReader {
    func read() -> ResourceMemoryCounters? {
        ResourceMemoryCounters(
            totalBytes: 1_000, pageSize: 100, freePages: 1, speculativePages: 0, purgeablePages: 0,
            compressedPages: 0)
    }
}

private struct StubNetworkReader: ResourceNetworkReader {
    func read() -> ResourceNetworkCounters? {
        ResourceNetworkCounters(receiveBytes: 10, transmitBytes: 20)
    }
}

private struct ImmediateResourceClock: ResourceClock {
    let now = Date(timeIntervalSince1970: 0)

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .milliseconds(1))
    }
}
