import AppKit

/// Owns camera state while the palette owns the visible surface.
@MainActor
@Observable
final class CameraCoordinator {
    /// `nil` while the camera warms up, which the stage shows as dark until video fades in.
    private(set) var feed: CameraSession.Feed?
    private(set) var canSwitchCamera = false
    var mirrored = true

    @ObservationIgnored private let session = CameraSession(.capture)
    @ObservationIgnored private unowned let core: AppCore
    @ObservationIgnored private var opening = false

    init(core: AppCore) { self.core = core }

    /// The screen opens at once, as Raycast's does; warm-up happens behind a dark stage.
    func showInPalette() async {
        guard !opening else { return }
        opening = true
        defer { opening = false }
        // The one wait kept up front: the prompt would take key from a palette already showing it.
        if Permissions.cameraAccess() == .notDetermined {
            _ = await Permissions.requestCameraAccess()
        }
        feed = nil
        canSwitchCamera = false
        core.paletteCoordinator.navigate(to: .camera)
        let started = await session.start()
        // Settled with no camera screen up: release it, or the light stays on for nothing.
        guard core.palette.mode == .camera, core.paletteCoordinator.isVisible else {
            session.stop()
            return
        }
        feed = started
        canSwitchCamera = session.hasMultipleDevices
    }

    func stop() { session.stop() }

    func switchCamera() { Task { await session.switchToNextDevice() } }

    /// A photo completes the command: copy it, close the palette, and release the camera.
    func takePhoto() {
        guard case .live = feed else { return }
        let mirrored = mirrored
        Task {
            let png = await session.capturePhoto(mirrored: mirrored)
            core.paletteCoordinator.hidePalette()
            guard let png else {
                core.showMessage("Couldn't take the photo", tone: .danger)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
            core.showMessage("Photo copied")
        }
    }

}
