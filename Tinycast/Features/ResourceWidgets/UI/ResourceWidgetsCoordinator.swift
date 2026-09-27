import SwiftUI

@MainActor
@Observable
final class ResourceWidgetsCoordinator {
    private let settings: AppSettings
    @ObservationIgnored private let loop: ResourceSamplingLoop
    @ObservationIgnored private lazy var panelController = ResourceWidgetsPanelController(
        coordinator: self)
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var panelOpen = false
    @ObservationIgnored private var paletteShowing = false
    @ObservationIgnored private var samplingGeneration = 0

    /// Only while the panel or the launcher's pills are up: nothing samples in the background.
    private var samplingEnabled: Bool { panelOpen || paletteShowing }

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
        panelOpen = true
        panelController.show(metrics: settings.interfaceSize.metrics)
        updateSampling()
    }

    func close() {
        guard panelOpen || isVisible else { return }
        panelOpen = false
        panelController.close()
        updateSampling()
    }

    /// The palette reports its visibility; the pills only read while it is on screen.
    func setPaletteShowing(_ showing: Bool) {
        guard paletteShowing != showing else { return }
        paletteShowing = showing
        updateSampling()
    }

    private func updateSampling() {
        if samplingEnabled { startSamplingIfNeeded() } else { stopSampling() }
    }

    /// Keeps `snapshot`, so the next start fills its first delta-less sample from it.
    private func stopSampling() {
        guard samplingTask != nil else { return }
        samplingGeneration += 1
        samplingTask?.cancel()
        samplingTask = nil
        history.reset()
    }

    private func startSamplingIfNeeded() {
        guard samplingTask == nil else { return }
        history.reset()
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
                    self.snapshot = sample.filling(from: self.snapshot)
                    self.history.append(sample)
                }
            }
        }
    }
}
