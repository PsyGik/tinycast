import AVFoundation
import AppKit

/// `AVCaptureSession` is not `Sendable`, so the blocking calls go off main behind a box.
@MainActor
final class CameraSession {
    /// What the session is built for; taking a photo costs a larger preset and an extra output.
    enum Purpose {
        case preview
        case capture
    }

    /// What `start()` settles on; a caller that shows its stage early renders `nil` until then.
    enum Feed {
        case live(AVCaptureSession)
        case denied
        case noCamera
    }

    /// Every camera the Mac offers right now, in the order `switchToNextDevice` cycles them.
    nonisolated static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    private let purpose: Purpose
    private var capture: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var device: AVCaptureDevice?
    private var deviceCount = 0
    private var pendingPhoto: PhotoCapture?
    /// Bumped by `stop()`, so a start still in flight knows it was abandoned.
    private var generation = 0

    init(_ purpose: Purpose = .preview) {
        self.purpose = purpose
    }

    /// Settles once running; a `stop()` that lands mid-start wins, and the late session stops here.
    func start() async -> Feed {
        var access = Permissions.cameraAccess()
        if access == .notDetermined {
            _ = await Permissions.requestCameraAccess()
            access = Permissions.cameraAccess()
        }
        guard access == .granted else { return .denied }
        let token = generation
        if capture == nil {
            let seed = CaptureBox(device: device?.isConnected == true ? device : nil)
            let purpose = purpose
            let built = await Task.detached {
                Signposts.interval("CameraSession.configure") { Self.configure(seed, purpose: purpose) }
            }.value
            guard let built, let session = built.session else { return .noCamera }
            // Abandoned while configuring: nothing runs yet, so dropping it is enough.
            guard token == generation else { return .noCamera }
            capture = session
            photoOutput = built.output
            device = built.device
            deviceCount = built.deviceCount
        }
        guard let capture else { return .noCamera }
        guard !capture.isRunning else { return .live(capture) }
        let box = CaptureBox(session: capture)
        await Task.detached {
            Signposts.interval("CameraSession.startRunning") { box.session?.startRunning() }
        }.value
        // `stop()` saw it not yet running and left it; the light must not outlive the caller.
        guard token == generation else {
            Self.stopRunning(capture)
            return .noCamera
        }
        return .live(capture)
    }

    func stop() {
        generation += 1
        guard let capture else { return }
        // A reused session without an output of its own feeds a new preview layer no frames.
        self.capture = nil
        photoOutput = nil
        guard capture.isRunning else { return }
        Self.stopRunning(capture)
    }

    var hasMultipleDevices: Bool { deviceCount > 1 }

    /// Only the input swaps: the session keeps running, so the stage never blanks to black.
    func switchToNextDevice() async {
        let devices = Self.devices
        guard devices.count > 1, let capture, let device else { return }
        // A device the discovery session does not list wraps to the first one rather than sticking.
        let index = devices.firstIndex(of: device) ?? devices.count - 1
        let next = devices[(index + 1) % devices.count]
        guard let input = try? AVCaptureDeviceInput(device: next) else { return }
        let box = CaptureBox(session: capture, input: input)
        await Task.detached {
            guard let session = box.session else { return }
            session.beginConfiguration()
            for existing in session.inputs { session.removeInput(existing) }
            if let input = box.input, session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
        }.value
        self.device = next
    }

    /// PNG rather than the camera's own encoding, so the clipboard history records it as an image.
    func capturePhoto(mirrored: Bool) async -> Data? {
        guard let photoOutput, capture?.isRunning == true else { return nil }
        if let connection = photoOutput.connection(with: .video),
            connection.isVideoMirroringSupported
        {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        let capture = PhotoCapture()
        pendingPhoto = capture
        defer { pendingPhoto = nil }
        guard let encoded = await capture.take(from: photoOutput) else { return nil }
        return await Task.detached {
            NSBitmapImageRep(data: encoded)?.representation(using: .png, properties: [:])
        }.value
    }

    /// The light goes out now rather than at deallocation, which could be long after the screen.
    private static func stopRunning(_ capture: AVCaptureSession) {
        let box = CaptureBox(session: capture)
        Task.detached { box.session?.stopRunning() }
    }

    /// Off main: opening the device and wiring the photo output can stall several frames.
    nonisolated private static func configure(_ seed: CaptureBox, purpose: Purpose) -> CaptureBox? {
        guard let device = seed.device ?? AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return nil }
        let capture = AVCaptureSession()
        capture.sessionPreset = purpose == .capture ? .photo : .medium
        guard capture.canAddInput(input) else { return nil }
        capture.addInput(input)
        var built = CaptureBox(session: capture, device: device, deviceCount: devices.count)
        guard purpose == .capture else { return built }
        let output = AVCapturePhotoOutput()
        guard capture.canAddOutput(output) else { return built }
        capture.addOutput(output)
        built.output = output
        return built
    }
}

/// Confined to this file: the one carrier that moves capture objects between main and off main.
private struct CaptureBox: @unchecked Sendable {
    var session: AVCaptureSession?
    var input: AVCaptureDeviceInput?
    var output: AVCapturePhotoOutput?
    var device: AVCaptureDevice?
    var deviceCount = 0
}

/// Unchecked because the continuation is written on main and read once on AVFoundation's queue.
private final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Data?, Never>?

    @MainActor
    func take(from output: AVCapturePhotoOutput) async -> Data? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        continuation?.resume(returning: error == nil ? photo.fileDataRepresentation() : nil)
        continuation = nil
    }
}
