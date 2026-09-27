import Foundation

struct ResourceCPUCounters: Equatable, Sendable {
    let user: UInt64
    let nice: UInt64
    let system: UInt64
    let idle: UInt64

    var total: UInt64 { user &+ nice &+ system &+ idle }
    var nonIdle: UInt64 { user &+ nice &+ system }
}

struct ResourceMemoryCounters: Equatable, Sendable {
    let totalBytes: UInt64
    let pageSize: UInt64
    let freePages: UInt64
    let speculativePages: UInt64
    let purgeablePages: UInt64
    let compressedPages: UInt64
    let swapUsedBytes: UInt64?

    init(
        totalBytes: UInt64,
        pageSize: UInt64,
        freePages: UInt64,
        speculativePages: UInt64,
        purgeablePages: UInt64,
        compressedPages: UInt64,
        swapUsedBytes: UInt64? = nil
    ) {
        self.totalBytes = totalBytes
        self.pageSize = pageSize
        self.freePages = freePages
        self.speculativePages = speculativePages
        self.purgeablePages = purgeablePages
        self.compressedPages = compressedPages
        self.swapUsedBytes = swapUsedBytes
    }
}

struct ResourceNetworkInterface: Equatable, Sendable {
    let isUp: Bool
    let isLoopback: Bool
    let receiveBytes: UInt64
    let transmitBytes: UInt64
}

struct ResourceNetworkCounters: Equatable, Sendable {
    let receiveBytes: UInt64
    let transmitBytes: UInt64

    init(receiveBytes: UInt64, transmitBytes: UInt64) {
        self.receiveBytes = receiveBytes
        self.transmitBytes = transmitBytes
    }

    init(interfaces: [ResourceNetworkInterface]) {
        let active = interfaces.filter { $0.isUp && !$0.isLoopback }
        receiveBytes = active.reduce(0) { $0 &+ $1.receiveBytes }
        transmitBytes = active.reduce(0) { $0 &+ $1.transmitBytes }
    }
}

struct ResourceMemoryUsage: Equatable, Sendable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let usedPercentage: Double
    let compressedBytes: UInt64
    let swapUsedBytes: UInt64?
}

struct ResourceNetworkRates: Equatable, Sendable {
    let receiveBytesPerSecond: Double
    let transmitBytesPerSecond: Double
}

enum ResourceGPUState: Equatable, Sendable {
    case unavailable

    var value: Double? {
        nil
    }
}

struct ResourceSnapshot: Equatable, Sendable {
    let timestamp: Date
    let cpuUtilization: Double?
    let memory: ResourceMemoryUsage?
    let network: ResourceNetworkRates?
    let gpu: ResourceGPUState

    init(
        timestamp: Date,
        cpuUtilization: Double? = nil,
        memory: ResourceMemoryUsage? = nil,
        network: ResourceNetworkRates? = nil,
        gpu: ResourceGPUState = .unavailable
    ) {
        self.timestamp = timestamp
        self.cpuUtilization = cpuUtilization
        self.memory = memory
        self.network = network
        self.gpu = gpu
    }
}

enum ResourceMetrics {
    static func cpuUtilization(
        current: ResourceCPUCounters, previous: ResourceCPUCounters?
    ) -> Double? {
        guard let previous,
            current.user >= previous.user,
            current.nice >= previous.nice,
            current.system >= previous.system,
            current.idle >= previous.idle
        else { return nil }

        let totalDelta = current.total &- previous.total
        guard totalDelta > 0 else { return nil }
        let nonIdleDelta = current.nonIdle &- previous.nonIdle
        return min(1, max(0, Double(nonIdleDelta) / Double(totalDelta)))
    }

    static func memoryUsage(from counters: ResourceMemoryCounters) -> ResourceMemoryUsage {
        let pageSize = counters.pageSize
        let reclaimablePages = counters.freePages
            &+ counters.speculativePages
            &+ counters.purgeablePages
        let totalPages = pageSize == 0 ? 0 : counters.totalBytes / pageSize
        let usedPages = totalPages > reclaimablePages ? totalPages - reclaimablePages : 0
        let usedBytes = usedPages &* pageSize
        let usedPercentage = counters.totalBytes == 0
            ? 0
            : Double(usedBytes) / Double(counters.totalBytes)

        return ResourceMemoryUsage(
            totalBytes: counters.totalBytes,
            usedBytes: usedBytes,
            usedPercentage: min(1, max(0, usedPercentage)),
            compressedBytes: counters.compressedPages &* pageSize,
            swapUsedBytes: counters.swapUsedBytes)
    }

    static func networkRates(
        current: ResourceNetworkCounters,
        previous: ResourceNetworkCounters?,
        elapsed: TimeInterval
    ) -> ResourceNetworkRates? {
        guard let previous, elapsed.isFinite, elapsed > 0,
            current.receiveBytes >= previous.receiveBytes,
            current.transmitBytes >= previous.transmitBytes
        else { return nil }

        return ResourceNetworkRates(
            receiveBytesPerSecond: Double(current.receiveBytes - previous.receiveBytes) / elapsed,
            transmitBytesPerSecond: Double(current.transmitBytes - previous.transmitBytes)
                / elapsed)
    }
}

struct ResourceHistory: Equatable, Sendable {
    static let defaultCapacity = 60

    let capacity: Int
    private(set) var samples: [ResourceSnapshot] = []

    init(capacity: Int = Self.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ sample: ResourceSnapshot) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
