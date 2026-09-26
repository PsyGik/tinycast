import AppKit

/// Owns camera state while the palette owns the visible surface.
@MainActor
@Observable
final class CameraCoordinator {
    private(set) var feed: CameraSession.Feed = .noCamera
    private(set) var canSwitchCamera = false
    var mirrored = true

    @ObservationIgnored private let session = CameraSession(.capture)
    @ObservationIgnored private unowned let core: AppCore
    @ObservationIgnored private var opening = false

    init(core: AppCore) { self.core = core }

    /// The session settles before the screen is visible, so its first frame is never black.
    func showInPalette() async {
        guard !opening else { return }
        opening = true
        defer { opening = false }
        feed = await session.start()
        canSwitchCamera = session.hasMultipleDevices
        core.paletteCoordinator.navigate(to: .camera)
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
