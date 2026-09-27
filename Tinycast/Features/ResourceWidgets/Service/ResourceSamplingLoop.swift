import Foundation

protocol ResourceClock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

struct SystemResourceClock: ResourceClock {
    var now: Date { Date() }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

struct ResourceSamplingLoop: Sendable {
    let readers: ResourceSamplingReaders
    let clock: any ResourceClock
    let interval: Duration

    init(
        readers: ResourceSamplingReaders = .system,
        clock: any ResourceClock = SystemResourceClock(),
        interval: Duration = .seconds(1)
    ) {
        self.readers = readers
        self.clock = clock
        self.interval = interval
    }

    func run(publish: @escaping @Sendable (ResourceSnapshot) async -> Void) async {
        var collector = ResourceMetricsCollector(readers: readers)
        while !Task.isCancelled {
            await publish(collector.sample(at: clock.now))
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
        }
    }
}
