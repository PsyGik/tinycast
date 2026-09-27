# Resource widgets

Live CPU, memory and network readings in two places: the **Resource Widgets** panel (the command, and
the menu bar item), with sparklines over the last minute, and three compact pills in the launcher's
footer, controlled by General › Search › **Show system stats** (on by default).

## Invariants

- **Nothing samples in the background.** `ResourceWidgetsCoordinator` samples once a second only while
  the panel is open or the palette is on screen (`setPaletteShowing`, driven by
  `PaletteWindowController.show` and `hide`), and stops the moment neither needs it.
- **The model stays pure.** `ResourceSnapshot`, `ResourceMetrics` and `ResourceReadout` under `Model/`
  import Foundation only; the system counters are read by `ResourceSystemReaders`, and every rate or
  percentage is a pure function of two counter samples.
- **Only the pills read the snapshot in the palette.** `ResourcePills` is the one palette view that
  observes `snapshot`, so a sample redraws three pills and never the palette body or the result list,
  whose re-render is the launcher's per-keystroke cost.
- **A restart never flashes a dash.** CPU and network are deltas, so the first sample after sampling
  starts has none. Stopping keeps `snapshot`, and `ResourceSnapshot.filling(from:)` carries its readings
  into the next first sample; the panel's `history` records raw samples, so sparklines never show a
  carried value as fresh.
- **Pills are shaped like the footer's keycaps**: `footerKeyCapHeight` tall, the `keyCap` radius and the
  `controlSurface` fill, with a `resourcePillGlyph` symbol and monospaced digits so values do not shift.

## How it is put together

| File | Role |
| --- | --- |
| `Model/ResourceSnapshot.swift` | counters, the snapshot, CPU/memory/network maths, the bounded history |
| `Model/ResourceReadout.swift` | the pills' text (percent, decimal byte rates) and `filling(from:)` |
| `Service/ResourceSystemReaders.swift` | host CPU ticks, VM statistics and interface byte counters |
| `Service/ResourceSamplingLoop.swift` | the once-a-second loop, clock injected for tests |
| `UI/ResourceWidgetsCoordinator.swift` | who needs sampling (panel, palette), the snapshot and history |
| `UI/ResourcePills.swift` | the launcher footer's three pills |
| `UI/ResourceWidgetsPanel*.swift`, `UI/ResourceWidgetsView.swift` | the floating panel and its cards |

GPU is modelled as explicitly unavailable until a public reader exists.

## Tests

`Tests/resource-widgets-test.swift` covers the CPU, memory and network maths, the bounded history, the
readout formatting and restart filling, and that the sampling loop stops when cancelled.
