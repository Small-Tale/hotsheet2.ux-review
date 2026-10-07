# 04 — Capture

Status: screenshots (`HS2-E89PQR`) and video recording (`HS2-W68HWK`) implemented on macOS.
The menu, global hotkey, and settings are in [05-start-and-settings.md](05-start-and-settings.md).

Capture turns "what is on screen right now" into a file in the current **draft review**,
together with where it came from. Annotating ([06-annotation-editor.md](06-annotation-editor.md))
and submitting (`HS2-CRJDJ8`) drafts are separate steps.

## 4.1 Requests

A capture request (`CaptureRequest`) has three parts:

| Field | Values |
| --- | --- |
| `kind` | `screenshot` or `video` |
| `target` | `display`: the whole display under the pointer. `window`: one window, picked by clicking. `region`: a rectangle dragged out on one display. |
| `delaySeconds` | `0`–`60`. The menus offer the presets 0, 3, 5, and 10. Values outside the range are clamped. For video, this delays the start of recording. |

The menu bar menu (see [05-start-and-settings.md](05-start-and-settings.md) for its full layout,
the default capture, and the global hotkey) offers "Screenshot of Screen / Window / Region" and a "Screenshot After
Delay" submenu, which lists each preset for each target.

- While a countdown runs, the menu instead offers "Cancel Capture".
- Captures don't overlap: a new request is ignored while one is already running.

## 4.2 Picking a target

- **Display**: no UI. The display under the pointer is captured.
- **Region**: every display is dimmed and shows a crosshair and the hint "Drag to select a
  region · Esc to cancel".
  - The drag stays on the display where it started.
  - A label next to the selection shows its size in pixels. The label goes below the
    selection, or above it near the bottom edge, and is drawn inside only when neither fits.
  - A drag smaller than 4 pt on either side counts as a click, and the overlay waits for a
    new drag.
- **Window**: the frontmost ordinary window under the pointer is highlighted and labeled
  "App · Title". Clicking captures it.
  - Only layer-0 windows that are visible and at least 40×40 pt can be picked.
  - UX Review's own windows are skipped.
- **Esc** cancels silently.
- When picking ends, the app that was frontmost before is reactivated, so its hover and focus
  states survive the delay.

## 4.3 Delay and countdown

When the request has a delay, the countdown runs **after** the target is picked. This leaves
time to open a menu or hover over a control.

- A floating HUD shows the remaining seconds in the middle of the target display. It never
  takes focus or mouse events.
- After capture, a HUD briefly shows "Saved capture-N.png" and how many captures the review now
  has.
- All of UX Review's windows (overlays, HUDs) are excluded from display and region captures.
  Window captures contain only the chosen window.

## 4.4 Pixels

- Captures use ScreenCaptureKit (`SCScreenshotManager`, macOS 14+) at native resolution
  (`captureResolution = .best`), with no cursor and no window shadow.
- Region math (`RegionGeometry`) converts the dragged rectangle in three steps:
  1. from AppKit's global, bottom-left coordinates
  2. to display-local, top-left points
  3. snapped outward to whole pixels and clipped to the display
- Images are written as PNG. `MediaItem.pixelWidth` and `pixelHeight` are the image's real
  pixel size.

## 4.5 Context

Every capture records a `CaptureContext`, taken at the moment of capture (after any delay):

| Field | Source |
| --- | --- |
| `appName`, `bundleIdentifier` | The app that owns the captured window. For a region, the topmost window under the region's center. For a display, the frontmost app (never UX Review itself). |
| `windowTitle` | That window's title. The window server only reveals titles once Screen Recording is granted. |
| `osVersion` | For example `macOS 27.0`, or `macOS 14.6.1` when there is a patch version |
| `displayScale` | Pixels per point of the capture |

Blank values are dropped. The context is stored on the media item (`media[].context`). The
review's own `context` is copied from its first capture. The intake ticket lists each media
item's source app and window ([03-hotsheet-integration.md](03-hotsheet-integration.md)).

## 4.6 Draft reviews

`ReviewDraftStore` keeps reviews in progress under
`~/Library/Application Support/UX Review/Drafts/` (`UXREVIEW_DRAFTS_DIR` overrides the
location):

```
Drafts/
  current                   name of the current draft directory
  20261007-031500-4F2A9C/
    review.json             uxreview/bundle/v1 bundle, media appended per capture
    capture-1.png
    capture-2.png
    originals/              untouched copies of cropped images (docs/06 §6.6), never attached
```

- **First capture**: creates a draft. Its title is "<App> review", or "UX review" when the app
  is unknown.
- **Later captures**: append to the current draft as `capture-N.<ext>` (with media ids `mN`).
- **"Start New Review"** (menu): ends the current draft. The next capture starts a new one, and
  old drafts stay on disk.
- **Pointer problems**: if the `current` pointer is stale (its directory is gone), the next
  capture starts a new draft. A pointer that tries to leave the drafts directory is ignored.
- **Failures**: a failed add leaves the draft unchanged and keeps the captured file.
- **Corrupt draft**: a draft whose `review.json` is corrupt is reported, not overwritten.
- **Editing**: the annotation editor saves with `ReviewDraftStore.update`, which re-reads and
  rewrites `review.json` under the store's lock, so captures appended while it is open are kept
  ([06-annotation-editor.md](06-annotation-editor.md) §6.7).

## 4.7 Permission and errors

- Capturing needs **Screen Recording** permission. The first attempt triggers the system
  prompt.
- If permission is denied, an alert explains the fix and offers "Open System Settings".
  macOS applies a newly granted permission only after the app relaunches.
- A display or window that disappears before capture gives "… is no longer available".

## 4.9 Video recording

The menu offers "Record Video of Screen / Window / Region" and "Record Video After Delay". The
global hotkey also records when Settings sets the default kind to Video.

Starting a recording uses the same picking and countdown as a screenshot; the countdown HUD
reads "Recording in…". Once recording begins:

- The menu bar icon turns into a record symbol.
- A HUD says "Recording" and explains how to stop.
- **Stop** with "Stop Recording (m:ss)" at the top of the menu, or with the global hotkey.
- If the display or window goes away, the recording stops by itself and keeps what was
  recorded.
- After stopping, a HUD shows "Saved capture-N.mov", the length, and how many captures the
  review now has.

How the movie is made:

- ScreenCaptureKit `SCStream` captures at up to 30 fps at native resolution, showing the cursor.
  `VideoFileWriter` (AVAssetWriter) encodes it as an H.264 QuickTime `.mov`.
- Only *complete* frames are written. ScreenCaptureKit sends no new frames while the screen is
  static, so the movie runs from the first frame to the moment Stop was pressed, not to the last
  frame. Otherwise a static screen would yield a near-empty clip.
- H.264 needs even dimensions. Region recordings are trimmed by at most one pixel on the right
  and bottom (`DisplayRegion.evenSized`).
- The capture context is taken when recording starts. `capturedAt` is the start time.
- The `MediaItem` has `kind: "video"`, its pixel size, and `durationMs`.

**Microphone narration** is deliberately not included yet. ScreenCaptureKit only captures the
microphone on macOS 15+, and narration needs its own permission flow. It is tracked as
`HS2-T0EY2W`.

## 4.10 Capture life cycle

`CapturePhase` enforces one capture at a time:

```
idle → picking → countingDown(n…1) → capturing → idle                (screenshot)
idle → picking → countingDown(n…1) → capturing → recording → finishing → idle  (video)
```

- Cancel (Esc, the menu, or the hotkey) is only valid while picking or counting down.
- A recording can only be **stopped**, never discarded: a failure while recording also goes
  through `finishing`.
- Invalid events are ignored, for example a second start while busy or stop during a
  countdown.
- Any unexpected error returns to `idle`.

## 4.11 Headless modes (tests and scripts)

```
UXReview --capture screenshot|video [--target display|window|region] [--delay N] [--duration S]
         [--display-id N] [--window-id N] [--rect x,y,w,h] [--drafts-dir DIR] [--new-review]
UXReview --render-ui-previews DIR
```

**`--capture`** makes one capture with no UI and prints one JSON object.

- On success: `status: "captured"`, `file`, `draftDirectory`, `media`, `bundleContext`,
  `delayMs`, `backend`.
- On failure: `status: "error"`, `error`, `message`.
- Target flags:
  - `region` needs `--rect`, in display-local, top-left points.
  - `window` uses `--window-id`, or else the frontmost app's front window.
  - `--display-id` defaults to the main display.
- Video needs `--duration` (seconds, up to 600). The recording runs for that long after the
  delay.

| Exit code | Meaning |
| --- | --- |
| 0 | Captured |
| 2 | `invalidArguments` (also for a region that is off the display or too small) |
| 4 | `permissionDenied` |
| 5 | `targetUnavailable` or `captureFailed` |

**`UXREVIEW_CAPTURE_BACKEND=synthetic`** replaces ScreenCaptureKit with a test card of the
exact pixel size the real capture would have. For video, it feeds 10 fps of test-card frames,
host-clock timestamped, through the real `VideoFileWriter`. Target resolution, delay, context, PNG writing,
and the draft store all still run for real. It exists so `scripts/app-e2e.sh` can cover the
pipeline on machines without Screen Recording permission.

**`--render-ui-previews`** draws the picker overlays and HUDs offscreen into PNGs, for visual
QA without screen capture.
