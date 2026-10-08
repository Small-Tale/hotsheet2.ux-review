# 04 — Capture

Status: screenshots (`HS2-E89PQR`) and video recording (`HS2-W68HWK`) implemented on macOS.
The menu, global hotkey, and settings are in [05-start-and-settings.md](05-start-and-settings.md).

Capture turns "what is on screen right now" into a file in the current **draft review**,
together with where it came from. Annotating ([06-annotation-editor.md](06-annotation-editor.md))
and submitting ([07-review-session.md](07-review-session.md)) drafts are separate steps.

## 4.1 Requests

A capture request (`CaptureRequest`) has three parts:

| Field | Values |
| --- | --- |
| `kind` | `screenshot` or `video` |
| `target` | `display`: the whole display under the pointer. `window`: one window, picked by clicking. `region`: a rectangle dragged out on one display. |
| `delaySeconds` | `0`–`60`. The menus offer the presets 0, 3, 5, and 10. Values outside the range are clamped. For video, this delays the start of recording. |

The menu bar menu's **Capture Image** submenu offers **Immediate** and **Delayed [3 s | 10 s]**
for the default target. The app menu bar's **Capture** menu, shown while a UX Review window is
open, offers "Screenshot of Screen / Window / Region" and a "Screenshot After Delay" submenu
listing each preset for each target. See [05-start-and-settings.md](05-start-and-settings.md)
§5.1 for both layouts, the default capture, and the global hotkeys.

- While a countdown runs, the menu instead offers "Cancel Capture".
- Captures don't overlap: a new request is ignored while one is already running.

## 4.2 Picking a target

The region and window overlays never activate UX Review. They are non-activating panels that
still take the keyboard, so Esc works, while every app's windows stay in the order the
reviewer sees. In particular UX Review's own windows (editor, Submit Review, Draft Reviews,
Settings) are not raised over the app being reviewed (HS2-AR8Q2G).

- **Display**: no UI. The display under the pointer is captured.
- **Region**: every display is dimmed and shows a crosshair and the hint "Drag to select a
  region · Space: window · Return: whole screen · Esc to cancel".
  - The drag stays on the display where it started.
  - A label next to the selection shows its size in pixels. The label goes below the
    selection, or above it near the bottom edge, and is drawn inside only when neither fits.
  - A drag smaller than 4 pt on either side counts as a click, and the overlay waits for a
    new drag.
- **Window**: the frontmost app window under the pointer is highlighted and labeled
  "App · Title". Clicking captures it.
  - Windows are hit-tested in the window server's front-to-back order, so a small window on
    top always wins over a large window behind it.
  - The window list is live (`LiveWindowList`, `HS2-VJ8VE8`). Windows that move, resize, open,
    close, or change order during the pick are followed:
    - Pointer moves re-read the list at most every 50 ms.
    - A 0.2 s timer re-reads it while the pointer is still, and moves the highlight if the
      window under the pointer changed.
    - A click always re-reads it first, so it picks what is under the pointer at that moment.
  - App window levels below the Dock can be picked: normal windows (layer 0), floating panels
    and palettes (3), modal panels (8), and utility windows (19). The Dock, the menu bar,
    status items, menus, and system overlays never can.
  - A window must be visible and at least 40×40 pt.
  - With several displays there is one overlay per display. Every mouse point is converted
    through the window its event belongs to, not the overlay view receiving it, so hovering on
    any display highlights the window a click there would pick (`RegionGeometry.globalPoint`,
    `HS2-DX2D41`).
  - UX Review's own windows are never picked, but they still cover what is behind them. When
    one is on top under the pointer, nothing is highlighted and a click does nothing, rather
    than picking a window the reviewer cannot see. UX Review's windows above the app levels
    (the capture HUD, the picker overlay) do not count.
  - The default headless window target and the capture context's window name still use the
    app's frontmost normal (layer-0) window, never a floating palette.
- **Switching while picking** (`PickerKeys`, `HS2-8NATQR`), like macOS ⌘⇧4, so the target can
  change without opening a window (for example from the menu bar menu's quick capture):
  - **Space** switches region ⇄ window. The drag or highlight starts over; in window mode the
    window under the pointer is highlighted at once. Space is ignored mid-drag, and a held
    Space switches only once.
  - **Return** (or keypad Enter) captures the whole display under the pointer.
  - The window hint reads "Click a window to capture it · Space: region · Return: whole screen ·
    Esc to cancel".
  - The capture is then what was picked: a window or a whole display, even from Capture Region
    (a recording too).
- **Esc** cancels silently.
- When picking ends, focus stays where it was, so the reviewed app's hover and focus states
  survive the delay.
  - If UX Review did become active during picking, the app that was frontmost before is
    reactivated, unless the reviewer switched to a third app meanwhile.
  - If UX Review was frontmost when picking began, its key window gets the keyboard back.

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
    edits.json              crops and trims, applied only when submitting (docs/06 §6.6), never attached
    numbering.json          highest capture-N / mN used, once a capture is removed (docs/07 §7.2), never attached
```

- **First capture**: creates a draft. Its title is "<App> review", or "UX review" when the app
  is unknown.
- **Later captures**: append to the current draft as `capture-N.<ext>` (with media ids `mN`).
  Numbers only go up: a removed capture's file name and id are never reused (docs/07 §7.2).
- **New Review** (File menu, ⌘N, `HS2-80CTK8`): creates a new, empty draft and makes it current,
  so the next captures go into it. Old drafts stay on disk. (`ReviewDraftStore.startNew()`,
  which only ends the current draft, remains for scripts and tests.) **Draft Reviews…** lists them so they can be reopened, submitted,
  or discarded (moved to the Trash) ([07-review-session.md](07-review-session.md) §7.9).
- **Pointer problems**: if the `current` pointer is stale (its directory is gone), the next
  capture starts a new draft. A pointer that tries to leave the drafts directory is ignored.
- **Failures**: a failed add leaves the draft unchanged and keeps the captured file.
- **Corrupt draft**: a draft whose `review.json` is corrupt is reported, not overwritten.
- **Editing**: the annotation editor saves with `ReviewDraftStore.update`, which re-reads and
  rewrites `review.json` under the store's lock, so captures appended while it is open are kept
  ([06-annotation-editor.md](06-annotation-editor.md) §6.7).
- **Submitting**: the review session files the draft in Hot Sheet and then deletes its folder
  (and the `current` pointer when it was current). If the ticket was created but attaching
  failed, the draft is kept with a `submission.json` record so the retry reuses that ticket
  ([07-review-session.md](07-review-session.md) §7.5).

## 4.7 Permission and errors

- Capturing needs **Screen Recording** permission. The first attempt triggers the system
  prompt.
- If permission is denied, an alert explains the fix and offers "Open System Settings".
  macOS applies a newly granted permission only after the app relaunches.
- If System Settings shows UX Review enabled but capture is still refused, the running build is
  signed differently from the one that was granted (ad hoc builds change identity on every
  rebuild). See [01-architecture.md](01-architecture.md) §1.3, "Code signing and permissions".
- A display or window that disappears before capture gives "… is no longer available".

## 4.9 Video recording

The menu offers "Record Video of Screen / Window / Region" and "Record Video After Delay". The
record-video hotkey (⌥⇧⌘V by default) records the default target from any app, and the capture
hotkey also records when Settings sets the default kind to Video
([05-start-and-settings.md](05-start-and-settings.md) §5.2).

Starting a recording uses the same picking and countdown as a screenshot; the countdown HUD
reads "Recording in…". Once recording begins:

- The menu bar icon turns into a record symbol.
- A HUD says "Recording" and explains how to stop.
- **Region recordings** dim the rest of that display slightly (black at 30 %), with a thin red
  outline just outside the recorded area, until the recording stops or fails (`HS2-122ZFZ`).
  - The dim sits above app windows and the Dock but below the menu bar, so the menu bar and
    the Stop control stay undimmed.
  - It ignores the mouse, so the reviewer keeps working in the region and anywhere else.
  - It never appears in the movie. ScreenCaptureKit's filter excludes all of UX Review's
    windows, and the dim window's `sharingType` is `.none` as well.
  - The clear area is the even-sized area that is actually recorded.
  - Window and screen recordings get no dim, and neither does headless `--capture video`.
- **Stop** with "Stop Recording (m:ss)" at the top of the menu, or with either global hotkey.
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

### Microphone narration

A recording can include the reviewer's voice as an AAC audio track (`HS2-T0EY2W`). It is opt-in:

- **Default:** Settings › Video › **Record microphone narration**, off unless turned on
  ([05-start-and-settings.md](05-start-and-settings.md) §5.3).
- **One recording:** the menu's **Narrate Next Recording with Microphone** checkbox shows the
  default and can flip it for the next recording only. Once that recording starts, it reverts to
  the default.
- While narrating, the "Recording" HUD says "Microphone on.", and the menu shows "Recording
  microphone narration" under Stop. The saved HUD says "narrated", or "no microphone audio
  received" if narration was on but no audio arrived.
- A narrated recording's `MediaItem` gets `hasAudio: true` when audio arrived (the same test as
  the "narrated" HUD), so `review.json` and the intake ticket show there is speech to listen to
  ([02-review-bundle.md](02-review-bundle.md) §2.2, `HS2-EZN3NG`). Headless capture prints it in
  `media` too.

**Permission.** Narration needs Microphone permission (`NSMicrophoneUsageDescription`, and the
hardened-runtime entitlement `com.apple.security.device.audio-input`). It is settled before the
target picker, so no question interrupts a countdown:

| Microphone state | What happens |
| --- | --- |
| Allowed | Records with narration. |
| Not asked yet | The system prompt appears. Allowing records with narration. Refusing continues as "Denied". |
| Denied | Alert "Microphone permission needed": **Record Without Narration**, **Open System Settings** (opens Privacy & Security › Microphone and cancels), or **Cancel**. |
| Restricted (e.g. by a profile) | The same alert without Open System Settings. |
| No microphone | Alert "No microphone for narration": **Record Without Narration** or **Cancel**. |

The recording never silently loses narration it was asked for: the reviewer chooses. Headless
mode never prompts and fails instead (§4.11).

**How the audio is recorded.** UX Review records the microphone itself rather than through
ScreenCaptureKit's `captureMicrophone` (a choice made when the deployment target was macOS 14):

- An `AVCaptureSession` on the default audio input delivers 48 kHz mono 16-bit LPCM.
- Each buffer's timestamp is converted from the session's clock to the host clock, which
  ScreenCaptureKit frames use.
- `VideoFileWriter` appends the buffers to a second, AAC input (96 kbps) of the same
  `AVAssetWriter`.

The tracks stay in sync because they share one timeline:

- Audio from before the first video frame is dropped, since the movie starts at that frame.
- Audio after the stop time is trimmed with the video (`endSession`).
- At the stop, the last frame is repeated at the stop time, so the video track itself reaches
  the end. Without that, AVFoundation ends a movie that has audio at its last sample, and a
  static screen whose audio ended early would be cut short.
- If the microphone fails or is unplugged mid-recording, the video carries on, and the narration
  ends there.
- Trimming in the editor ([06-annotation-editor.md](06-annotation-editor.md) §6.10) keeps the
  narration.

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
         [--narration] [--display-id N] [--window-id N] [--rect x,y,w,h] [--drafts-dir DIR] [--new-review]
UXReview --import FILE [FILE…] [--drafts-dir DIR] [--new-review]   (§4.12)
UXReview --open-media FILE [FILE…] [--drafts-dir DIR] [--into-draft DIR]   (§4.12.1)
UXReview --render-ui-previews DIR
```

**`--capture`** makes one capture with no UI and prints one JSON object.

- On success: `status: "captured"`, `file`, `draftDirectory`, `media`, `bundleContext`,
  `delayMs`, `backend`, and for video `narration` (whether the movie has a narration track).
- On failure: `status: "error"`, `error`, `message`.
- Target flags:
  - `region` needs `--rect`, in display-local, top-left points.
  - `window` uses `--window-id`, or else the frontmost app's front window.
  - `--display-id` defaults to the main display.
- Video needs `--duration` (seconds, up to 600). The recording runs for that long after the
  delay.
- `--narration` (video only) adds the microphone track (§4.9). Headless mode never shows the
  Microphone prompt: unless access is already granted, it fails with
  `microphonePermissionDenied` (exit 4), or `microphoneUnavailable` (exit 5) with no microphone,
  before recording anything.

| Exit code | Meaning |
| --- | --- |
| 0 | Captured |
| 2 | `invalidArguments` (also for a region that is off the display or too small) |
| 4 | `permissionDenied` or `microphonePermissionDenied` |
| 5 | `targetUnavailable`, `microphoneUnavailable`, or `captureFailed` |

**`UXREVIEW_CAPTURE_BACKEND=synthetic`** replaces ScreenCaptureKit with a test card of the
exact pixel size the real capture would have. For video, it feeds 10 fps of test-card frames,
host-clock timestamped, through the real `VideoFileWriter`. With `--narration` it also feeds a
440 Hz tone in 100 ms LPCM buffers from the first frame on, standing in for the microphone.
`UXREVIEW_SYNTHETIC_MICROPHONE` (`authorized`, the default, or `notDetermined`, `denied`,
`restricted`, `unavailable`) simulates the microphone's state. Target resolution, delay, context, PNG writing,
and the draft store all still run for real. It exists so `scripts/app-e2e.sh` can cover the
pipeline on machines without Screen Recording permission.

**`--render-ui-previews`** draws the picker overlays, the region-recording dim
(`recording-dim-region.png`), and the HUDs offscreen into PNGs, for visual QA without screen
capture. It also renders the Settings window, the menu bar icon on light and
dark strips (`status-bar-icon-light.png`, `status-bar-icon-dark.png`), and the annotation editor.

## 4.12 Opening existing media for annotation

Media captured elsewhere, such as a ⇧⌘4 screenshot on the Desktop or an older recording, can
be annotated without capturing it again (`HS2-6A13WZ`).

**Menu:** **Add Media…** (File menu or the editor tool bar, ⌘O) shows an open panel for images
and movies. Several files can be chosen at once. From an editor or Submit Review window, the
files go into that window's draft (§4.12.2). Otherwise UX Review:

1. Prepares every chosen file. If any one is missing, isn't an image or movie, or can't be
   read, an alert names it and **nothing** is added.
2. **Copies** the files into the current draft review, creating one if needed, in the order
   chosen, as `capture-N.<ext>` with media ids `mN`, just like captures (§4.6). The source
   files are never moved or changed.
3. Opens the annotation editor on the first imported item. If an editor window for that draft
   is already open, it picks up the new media and switches to it.

What an imported file becomes:

| Source | In the draft |
| --- | --- |
| Any image ImageIO reads (PNG, JPEG, HEIC, TIFF, GIF, …) | A PNG, with its EXIF orientation applied so it is upright, at full resolution. GIFs and multi-page files keep their first frame. Re-encoding makes every format behave like a capture in the editor (crop, render). |
| A movie AVFoundation reads that has a video track (`.mov`, `.mp4`, `.m4v`, …) | A byte-for-byte copy, keeping its extension. `pixelWidth`/`pixelHeight` are the displayed size, with the track's rotation applied, so annotations line up with the poster frame the editor shows. `durationMs` comes from the asset. `hasAudio: true` is set when the movie has any audio track ([02-review-bundle.md](02-review-bundle.md) §2.2). |

- `capturedAt` is the file's creation date.
- The media item has no `context`, because nothing is known about where the file came from.
  The first item of a new draft leaves the bundle context empty, and the title is "UX review".
- To put imported files in a review of their own, choose **New Review** (⌘N) first.

**Headless:**

```
UXReview --import FILE [FILE…] [--drafts-dir DIR] [--new-review]
```

This mode does the same import with no UI and prints JSON.

- On success: `status: "imported"`, `draftDirectory`, `files`, and `media`.
- On failure: `status: "error"`, with `error` set to `missingFile`, `unsupportedMedia`,
  `unreadableMedia`, `nothingToImport`, `invalidArguments`, or `failed`, plus a `message`.
- `--new-review` ends the current draft only once every file has been prepared, so a failed
  import leaves the current draft current.

| Exit code | Meaning |
| --- | --- |
| 0 | Imported |
| 2 | Bad arguments, or a file that is missing, unsupported, or unreadable. Nothing is imported. |
| 5 | The draft couldn't be written |

### 4.12.1 Opening from Finder

UX Review also accepts images and movies from outside the menu (`HS2-H1RNGK`):

- **Finder "Open With".** The app declares `public.image` and `public.movie` as document
  types, with role Viewer and `LSHandlerRank` Alternate (`macos/project.yml`). It is offered
  under **Open With**, but it never becomes the default app for those files.
- **Dropping files on the app icon** in the Dock or Finder.

Both arrive in `application(_:open:)` (`AppDelegate`). URLs delivered within 0.3 s of each
other are coalesced into **one batch**, because Launch Services may split a multi-file open
across several calls. The batch then goes through the same steps as the menu (§4.12): it is
imported into the **current** draft, creating one if needed, and the editor opens on the first
new item. This works when the app is already running, and also when the open launches it.

Before anything is copied, a pure routing step (`MediaOpenRouting.plan`) checks the batch:

- Duplicate files are dropped, and the first occurrence keeps its place. Paths are compared
  after standardizing and resolving symlinks.
- The **whole batch is rejected**, and nothing is imported, when any item is one of these:
  - not a file URL
  - missing
  - a folder, even one named like media (`shots.png/`)
  - not an image or movie by type (`notes.txt`, a file with no extension)
- The first problem in the order given is the one reported.
- An empty batch is rejected as `nothingToImport`.

A batch that passes the check goes through `MediaImporter.importFiles`, which is also all or
nothing. A file that looks like media but can't be read is rejected there.

A rejected batch shows the same alert as the menu, naming the file, and nothing is added.

### 4.12.2 Dragging files onto an editor window

Images and movies dragged from Finder onto an open editor window are **added to that window's
draft**, not to a new one. This holds even when that draft is no longer the current one, for
example after **New Review**. The drop doesn't change which draft is current.

The editor then switches to the first dropped item. The routing and the all-or-nothing rule
are the same as in §4.12.1.

- The window accepts every file drag, so a wrong file gets an explanation instead of just
  bouncing back.
- A rejected drop shows a sheet on the window, for example: "Couldn't add that media.
  notes.txt isn't an image or a movie. Nothing was added to the review."
- Drags that aren't files go to the editor as usual.

**Headless:** this mode routes files through the same plan and import, with no UI, and prints
JSON:

```
UXReview --open-media FILE [FILE…] [--drafts-dir DIR] [--into-draft DIR]
```

- Without `--into-draft`, files go into the current draft, as with Finder "Open With".
- With `--into-draft`, files go into that draft, as with a drop on its editor.
- On success: `status: "opened"`, `draftDirectory`, `editorMediaId` (the item the editor
  would show), and `media`.
- Errors and exit codes match `--import`. A missing `--into-draft` draft exits 5 (`failed`).

