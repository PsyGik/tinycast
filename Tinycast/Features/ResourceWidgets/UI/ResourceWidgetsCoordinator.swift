import SwiftUI

@MainActor
@Observable
final class ResourceWidgetsCoordinator {
    private let settings: AppSettings
    @ObservationIgnored private let loop: ResourceSamplingLoop
    @ObservationIgnored private lazy var panelController = ResourceWidgetsPanelController(
        coordinator: self)
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var samplingEnabled = false
    @ObservationIgnored private var samplingGeneration = 0

    private(set) var snapshot: ResourceSnapshot?
    private(set) var history = ResourceHistory()

    init(
        settings: AppSettings,
        readers: ResourceSamplingReaders = .system,
        clock: any ResourceClock = SystemResourceClock()
    ) {
        self.settings = settings
        loop = ResourceSamplingLoop(readers: readers, clock: clock)
    }

    var isVisible: Bool { panelController.isVisible }

    func show() {
        samplingEnabled = true
        panelController.show(metrics: settings.interfaceSize.metrics)
        startSamplingIfNeeded()
    }

    func close() {
        guard isVisible || samplingTask != nil else { return }
        samplingEnabled = false
        samplingGeneration += 1
        samplingTask?.cancel()
        samplingTask = nil
        snapshot = nil
        history.reset()
        panelController.close()
    }

    private func startSamplingIfNeeded() {
        guard samplingTask == nil else { return }
        history.reset()
        snapshot = nil
        samplingGeneration += 1
        let generation = samplingGeneration
        let loop = self.loop
        samplingTask = Task.detached(priority: .utility) { [weak self] in
            await loop.run { sample in
                await MainActor.run {
                    guard let self,
                        self.samplingEnabled,
                        self.samplingGeneration == generation
                    else { return }
                    self.snapshot = sample
                    self.history.append(sample)
                }
            }
        }
    }
}
