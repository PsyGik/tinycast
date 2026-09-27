import Darwin
import Foundation

protocol ResourceCPUReader: Sendable {
    func read() -> ResourceCPUCounters?
}

protocol ResourceMemoryReader: Sendable {
    func read() -> ResourceMemoryCounters?
}

protocol ResourceNetworkReader: Sendable {
    func read() -> ResourceNetworkCounters?
}

struct MachCPUReader: ResourceCPUReader {
    func read() -> ResourceCPUCounters? {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount,
            &processorInfo, &processorInfoCount)
        guard result == KERN_SUCCESS, let processorInfo else { return nil }
        defer {
            _ = vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: processorInfo)),
                vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var counters = ResourceCPUCounters(user: 0, nice: 0, system: 0, idle: 0)
        for processor in 0..<Int(processorCount) {
            let offset = processor * Int(CPU_STATE_MAX)
            counters = ResourceCPUCounters(
                user: counters.user &+ ticks(processorInfo[offset + Int(CPU_STATE_USER)]),
                nice: counters.nice &+ ticks(processorInfo[offset + Int(CPU_STATE_NICE)]),
                system: counters.system &+ ticks(processorInfo[offset + Int(CPU_STATE_SYSTEM)]),
                idle: counters.idle &+ ticks(processorInfo[offset + Int(CPU_STATE_IDLE)]))
        }
        return counters
    }

    private func ticks(_ value: integer_t) -> UInt64 {
        UInt64(max(0, value))
    }
}

struct SystemMemoryReader: ResourceMemoryReader {
    func read() -> ResourceMemoryCounters? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(getpagesize())
        return ResourceMemoryCounters(
            totalBytes: UInt64(ProcessInfo.processInfo.physicalMemory),
            pageSize: pageSize,
            freePages: UInt64(statistics.free_count),
            speculativePages: UInt64(statistics.speculative_count),
            purgeablePages: UInt64(statistics.purgeable_count),
            compressedPages: UInt64(statistics.compressor_page_count),
            swapUsedBytes: swapUsedBytes())
    }

    private func swapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = withUnsafeMutablePointer(to: &usage) {
            sysctlbyname("vm.swapusage", $0, &size, nil, 0)
        }
        return result == 0 ? usage.xsu_used : nil
    }
}

struct ActiveNetworkReader: ResourceNetworkReader {
    func read() -> ResourceNetworkCounters? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }

        var interfaces: [ResourceNetworkInterface] = []
        var current = addresses
        while let address = current {
            let entry = address.pointee
            let flags = entry.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                flags & UInt32(IFF_LOOPBACK) == 0,
                let socketAddress = entry.ifa_addr,
                Int32(socketAddress.pointee.sa_family) == AF_LINK,
                let data = entry.ifa_data
            else {
                current = entry.ifa_next
                continue
            }
            let statistics = data.assumingMemoryBound(to: if_data.self).pointee
            interfaces.append(
                ResourceNetworkInterface(
                    isUp: true,
                    isLoopback: false,
                    receiveBytes: UInt64(statistics.ifi_ibytes),
                    transmitBytes: UInt64(statistics.ifi_obytes)))
            current = entry.ifa_next
        }
        return ResourceNetworkCounters(interfaces: interfaces)
    }
}

struct ResourceSamplingReaders: Sendable {
    let cpu: any ResourceCPUReader
    let memory: any ResourceMemoryReader
    let network: any ResourceNetworkReader

    static let system = ResourceSamplingReaders(
        cpu: MachCPUReader(), memory: SystemMemoryReader(), network: ActiveNetworkReader())
}

struct ResourceMetricsCollector: Sendable {
    let readers: ResourceSamplingReaders
    private var previousCPU: ResourceCPUCounters?
    private var previousNetwork: ResourceNetworkCounters?
    private var previousTimestamp: Date?

    init(readers: ResourceSamplingReaders) {
        self.readers = readers
    }

    mutating func sample(at timestamp: Date) -> ResourceSnapshot {
        let cpu = readers.cpu.read()
        let memory = readers.memory.read().map(ResourceMetrics.memoryUsage)
        let network = readers.network.read()
        let elapsed = previousTimestamp.map { timestamp.timeIntervalSince($0) } ?? 0
        let snapshot = ResourceSnapshot(
            timestamp: timestamp,
            cpuUtilization: cpu.flatMap {
                ResourceMetrics.cpuUtilization(current: $0, previous: previousCPU)
            },
            memory: memory,
            network: network.flatMap {
                ResourceMetrics.networkRates(
                    current: $0, previous: previousNetwork, elapsed: elapsed)
            })
        previousCPU = cpu
        previousNetwork = network
        previousTimestamp = timestamp
        return snapshot
    }
}
