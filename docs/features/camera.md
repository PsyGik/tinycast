# Camera

One camera, two surfaces. `Open Camera` is a palette screen with a full-bleed live preview, while
Calendar's pre-meeting preview remains its separate panel. The command opens its screen at once over a
dark stage, hides the palette search header, keeps the normal 39pt footer below the preview, and fades
the video in once the capture session is running.

## Invariants

- **Nothing runs until the command is run.** `CameraCoordinator` is `lazy` on `AppCore`, and
  `CameraSession.init` stores a `Purpose` and touches nothing else — no device, no discovery session,
  no TCC read. The camera permission prompt is raised by `start()`, from the gesture that asked for
  it, and never on launch.
- **The screen opens at once; only the permission prompt waits.** `showInPalette()` asks for access
  first when it is undetermined, so the TCC prompt never takes key from a palette already up, then
  navigates to `.camera` immediately with `feed == nil`, which `CameraStage` draws as a black stage.
  `CameraSession.configure` builds the session, input and photo output off main, and `start()` settles
  once `startRunning` returns; the video fades in on that. Calendar still awaits `start()` before its
  panel appears, so it never sees `nil`.
- **The camera stops on every exit, including one mid-start.** Leaving the mode stops it from the
  screen's `onDisappear`. `PaletteWindowController.hide` stops it explicitly while the mode is still
  `.camera`, because an ordered-out window never fires `onDisappear`, and then leaves the screen, so a
  reopen never lands on a stage with no session behind it. `stop()` bumps a generation that a start
  still in flight checks: a session that finishes warming up after its screen has gone is stopped
  there, and the coordinator also stops it if it settles with no camera screen showing. `stop()` drops
  the `AVCaptureSession`, so every open builds its own: a reused session with no output of its own —
  the preview's — restarts to a black stage.
- **Escape, the back button, and the Actions menu return through palette navigation.** They use the
  existing Escape/back paths, so the configured Escape behavior remains honored. The screen has no
  focusable view, so SwiftUI's `onKeyPress(.escape)` never fires there; `PaletteWindowController`
  resolves a bare Escape at the panel's `onEscape` instead, through the same `PaletteEscapeAction`,
  whenever the camera screen is up with no menu open. Taking a photo closes
  the palette after copying it, and the mode/hide lifecycle releases the camera light.
- **The preview and the photo are mirrored together.** Mirroring is `isVideoMirrored` on a connection
  — the preview layer's, and the photo output's at capture time — never a `scaleEffect` on the view,
  which would hand back a photo that is not what the user framed.
- **The command uses the palette's own `⌘K` menu.** It lists Take Photo (↵), Mirror, Switch Camera
  when available, and Back to Search (Esc); no camera-specific popover or key routing remains.
- **A photo reaches the clipboard as PNG.** The camera's own encoding is decoded and re-encoded off
  main, because `ClipboardManager` records `.png` and `.tiff` and nothing else.
- **`AVCaptureSession` is not `Sendable`, and only `CaptureBox` crosses that line.** The blocking
  calls — building the session, `startRunning`, `stopRunning`, and the begin/commit around a device
  swap — run in
  `Task.detached` behind that one `@unchecked Sendable` box, which is private to `CameraSession.swift`.
  There is no second actor.

## How it is put together

| Piece | Holds |
| --- | --- |
| `Service/CameraSession.swift` | access, start/stop, device cycling, the photo, and the box |
| `UI/CameraCoordinator.swift` | palette session lifecycle, mirror state, and the clipboard write |
| `UI/CameraScreen.swift` | full-bleed palette preview, back button, footer context, and Actions rows |
| `UI/CameraStage.swift` | the shared stage — the hosted preview layer, or why there is no video |
| `UI/CameraPanel.swift` | Calendar's shared borderless preview panel: ↵ and Esc, cursor-screen centring |
| `UI/CameraButton.swift` | Calendar's join-preview button: `ModalActionButtonStyle` plus a key-cap tooltip |

`Purpose` is the session's one knob. `.preview` is the cheap one Calendar takes — a `.medium` preset
and no output. `.capture` raises the preset to `.photo` and adds an `AVCapturePhotoOutput`, which is
the whole cost of being able to take a photo, and it is paid only by the command that does.

`CameraCoordinator` is `@Observable` and the view reads it directly, so toggling Mirror re-renders
through Observation rather than through a hand-reassigned `rootView`. `mirrored` lives on the
coordinator rather than in `AppSettings`: it is remembered for the launch, and a display preference
that grants nothing is not worth a settings key or a line in a backup.

Switching cameras swaps the input inside one `beginConfiguration`/`commitConfiguration` while the
session keeps running, so the stage never blanks. The next open starts on the camera switched to,
unless it has been unplugged since. `Switch Camera` only appears when
`hasMultipleDevices` says the discovery session found more than one.

## Where it is reachable from

The launcher, as `CommandID.openCamera` — so it takes aliases and a global shortcut like any other
command, and hides with the `Command` category. It has no Settings pane and no enable switch: there
is nothing to configure and nothing to leave running.
