# Test coverage

Each feature gets both unit tests and end-to-end tests. Tests live in
`macos/Tests/UXReviewKitTests/` unless noted, and all of them run in `scripts/check.sh`.

## HS2-3ZSBZ9: repository foundation

- **Review bundle model and spec** (`ReviewBundleTests`):
  - the shared example decodes and validates, and round-trips losslessly
  - the encoder's output matches the committed example
  - the schema's enums match the model
  - Codable defaults and unknown shapes are handled
  - bounds projection per shape, including degenerate and clamped cases
  - default and explicit intents
  - The full JSON Schema validation of the examples runs in `scripts/check.sh` (ajv).
- **Validation** (`BundleValidationTests`): every `BundleIssue` rule, including boundary cases
  (an instant time range at the end of the clip, the out-of-bounds edge).
- **Ticket composition** (`TicketComposerTests`):
  - the full body for the example
  - the Hot Sheet projection, including the snake_case wire format
  - optional sections omitted
  - time formatting
- **CLI transport** (`HotSheetCLIClientTests`, using a fake process runner that matches real
  `hotsheet-cli` output):
  - bound arguments and `--` before files
  - AI actor environment removed from the child process
  - slug parsing, failures, and unexpected output
- **Discovery** (`HotSheetLocatorTests`, `HotSheetStatusTests`):
  - CLI lookup order
  - store as itself, pointer file found by walking up, sibling `.hs2`, `$HOTSHEET_STORE`, stale
    pointer
  - regression: the walk from a directory URL terminates at `/`
  - each status state
- **Submission** (`ReviewSubmitterTests`): one-batch attach, `review.json` contents, nothing
  written for an invalid bundle or missing media, no attach after a failed create.
- **End to end** (`HotSheetEndToEndTests`): submits the example bundle through the real
  `hotsheet-cli` into a freshly initialized store, then reads the ticket back. It checks the
  title, category, tag, all three attachments in one labeled `problem_evidence` batch with a
  `human` actor, the instructions and annotation sections, and that the stored `review.json` is
  byte-identical to what was written. The test is required in the gate
  (`UXREVIEW_REQUIRE_HOTSHEET=1`).
- **App** (`scripts/check.sh`): builds `UXReview.app` with Xcode and runs `UXReview --status`
  against a throwaway store, checking that it resolves the store. Menu UI tests and visual QA are
  tracked in `HS2-HA9TW3`.

## HS2-E89PQR: screenshot capture

- **Requests** (`CaptureRequestTests`): delay clamping and presets, the countdown sequence, menu
  summaries, and Codable defaults and clamping.
- **Region math** (`RegionGeometryTests`):
  - drag direction
  - bottom-left → top-left flip on primary and offset secondary displays
  - clipping, outward pixel snapping at 1x/2x/1.5x
  - rejection of tiny, offscreen, or zero-scale regions
  - the shared display edge
- **Window selection** (`WindowSelectionTests`):
  - topmost pickable window under a point
  - skipping our own PID, decorations, Dock-and-above or desktop layers, and invisible windows
  - floating windows (layers 1–19) pickable
  - a realistic front-to-back snapshot: small and floating windows on top win over large
    windows behind them (HS2-1JWVYC regression)
  - front window per app, which stays on layer 0
  - the picker's target: UX Review's own windows on top occlude rather than being skipped,
    while its HUD and overlay levels do not (HS2-AR8Q2G regression)
- **Picker focus** (`PickerFocusTests`): focus is handed back only when UX Review took it
  during picking; never after a switch to a third app, or when UX Review was frontmost.
  - coordinate flips
  - parsing window-server dictionaries
- **Context** (`CaptureContextBuilderTests`): OS version strings, trimming, and dropping blanks.
- **PNG files** (`ImageFilesTests`): write and read back, size, signature, error cases.
- **Draft store** (`ReviewDraftStoreTests`), a transition walk:
  - no draft → first capture → append → start new (repeated) → refill
  - a stale pointer, a pointer escaping the root, a corrupt draft (the capture is kept), a
    missing capture file (nothing is created)
  - filename collisions on disk
  - per-media and review-level context
  - monotonic numbering (`HS2-44ZXNE`): removing the last, a middle, or every capture never
    frees a file name or id; a failed removal records nothing; an unreadable `numbering.json`
    falls back to `review.json`; drafts without a record follow `review.json`
- **`--capture` parsing** (`CaptureCommandTests`): a full command, defaults, and 13 rejected
  argument shapes.
- **Ticket body**: per-media source labels (`TicketComposerTests`).
- **App end to end** (`scripts/app-e2e.sh`, which drives the built app):
  - Real ScreenCaptureKit backend: without permission, it must exit 4 with an explanation and
    write nothing. With permission, the PNG must match the reported size.
  - Synthetic backend, through the real pipeline: a display capture (PNG size and context), a
    region after a 1 s delay (exact pixel size, delay honored, appended to the same draft), a
    schema-valid draft `review.json` (ajv), and `--new-review`.
  - Error paths: a missing window (exit 5) and an invalid region or arguments (exit 2).
  - Offscreen UI previews render.
- **Not covered automatically:** real-pixel capture and interactive picking in a session with
  Screen Recording granted. That is tracked in `HS2-HA9TW3`. Overlay and HUD visuals were
  checked from `--render-ui-previews` output.

## HS2-DR107C: start from the menu bar and a global hotkey

- **Hotkey model** (`HotkeyTests`):
  - parsing the symbol and word forms (any order, case, or separator) and displaying in Apple's
    order
  - every supported key round-trips
  - Carbon key codes and masks match the Carbon headers
  - usability rules (needs ⌘/⌃/⌥, F-keys allowed alone)
  - Codable as the display string, plus rejected inputs
- **Settings** (`CaptureSettingsTests`):
  - defaults
  - save → load → change → disable → re-enable sequences
  - the exact stored JSON
  - partial, broken, or explicit-null values
  - real `UserDefaults` suites
- **Hotkey action** (`HotkeyActionTests`): the idle / counting-down / busy transition matrix.
- **`--settings` parsing** (`SettingsCommandTests`): read-only, apply, `none`, and rejected
  values.
- **App end to end** (`scripts/app-e2e.sh`, isolated defaults suite):
  - fresh defaults
  - set → relaunch → read shows the change persisted (also checked through `defaults read`) and
    the hotkey registered with the system
  - a **real conflict**: a running menu bar instance holds the hotkey, so a second registration
    reports `inUse`
  - disabling the hotkey
  - an unusable hotkey is rejected with exit 2 and not saved
  - Settings window renders in both registration states (visual QA)
- **Not covered automatically:** pressing the hotkey. Synthesizing a global key press needs
  Accessibility permission. Clicking menu items is also untested. Both are tracked in
  `HS2-HA9TW3`.

## HS2-W68HWK: video recording

- **Movie writer** (`VideoCaptureTests`):
  - writes a real H.264 `.mov` from 1.5 s of frames and stops at 2.0 s. The movie must last
    until the stop (AVFoundation reads back 2000 ms and the size).
  - out-of-order frames and frames after finish are dropped
  - finishing twice, or with no frames, fails and leaves no file
  - odd or tiny sizes are rejected
- **Even sizing**: one-pixel trims, and regions that are already even stay unchanged.
- **`--capture video`**: `--duration` is required, its range is checked, and screenshots reject
  it.
- **Life cycle** (`CapturePhaseTests`):
  - the full phase × event matrix (14 valid transitions, the rest ignored)
  - screenshot without delay
  - the full video life cycle with a countdown
  - adversarial events: a second start, stop during a countdown, a double stop, a late tick,
    cancel while recording
  - start again after finishing
- **Hotkey**: the action for every phase, including stopping a recording (`HotkeyActionTests`).
- **App end to end** (`scripts/app-e2e.sh`):
  - The real backend without permission exits 4 and writes nothing.
  - A synthetic 2 s region recording is checked: even-trimmed pixel size, `durationMs` about
    2000, and ffprobe confirming H.264, the size, and the duration. It is appended to the current
    draft after the screenshot, and the draft still validates.
  - A start delay is honored.
  - A missing `--duration` exits 2.
  - The recording HUDs render.
- **Not covered automatically:** real ScreenCaptureKit recording, the menu Stop item, and
  stopping with the hotkey. These are tracked in `HS2-HA9TW3`.

## HS2-9H7WZ8: annotation editor

- **State machine** (`AnnotationEditorTests`), as transition-matrix and adversarial walks:
  - drawing each shape; tiny drags; clamping
  - select, move, and resize, one undo step each; edge stops; no flip below the minimum
  - arrow vertices and freehand boxes
  - nested-shape picking
  - cancel for every gesture kind
  - interrupted gestures: switching media, undo mid-drag, double begin, stray update/end
  - coalesced note typing and nudges; no-op edits leave history alone
  - delete, duplicate, never-reused ids
  - Tab cycling
  - full undo/redo walks that restore media; history bound; dirty tracking
  - captures merged mid-session (and mid-gesture) survive undo
  - an empty review
  - `IntentToggle` over every intent × shape; `primaryIntent`
- **Crop and geometry** (`ImageCropTests`, `ShapeGeometryTests`):
  - snapping
  - boxes clipped, points pulled to the edge, outsiders removed
  - crops compose, undo, and redo; refused crops (tiny, whole, video)
  - reset crop
  - normalized ↔ pixel conversion; hit distance per shape; handles; translation clamps
- **Session and files** (`EditorSessionTests`, real PNGs in a real draft):
  - save and reload are identical
  - captures added mid-edit are kept
  - crops rewrite the PNG and keep `originals/`, and stay undoable after saving, across sessions
  - a missing image fails the save without touching `review.json`
  - the renderer strokes the right pixels
  - scripts drive the editor; script errors name the step
  - `--annotate` parsing
- **App end to end** (`scripts/app-e2e.sh`):
  - `--annotate` on synthetic screenshot + video drafts draws every shape with notes, intents,
    undo/redo, and delete+undo
  - crops the PNG (exact size, `originals/` kept, media size updated)
  - refuses to crop the video
  - validates `review.json` with ajv
  - renders annotated PNGs, including the video poster
  - reopens and edits in a second session
  - rejects missing drafts (exit 3) and bad scripts, failing steps, and escaping names (exit 2)
- **Visual QA**: `--render-ui-previews` renders the real editor views in six states (empty,
  selected rect, selected arrow, the 900 × 560 minimum, crop drag, cropped), each inspected by
  hand.
  - Live-window mouse/keyboard automation is part of `HS2-HA9TW3`.

## HS2-ZMXAP9: status bar icon

- **E2E** (`scripts/app-e2e.sh`): `--render-ui-previews` must write `status-bar-icon-light.png`
  and `status-bar-icon-dark.png`. The renderer fails if the `StatusBarIcon` asset is missing
  from the built app's asset catalog, so a dropped resource breaks the gate.
- **Visual QA:** both renders checked by eye: template tinting follows the strip's appearance,
  and the icon matches the weight and size of neighbouring system symbols.
- **Not covered automatically:** the live menu bar (needs Screen Recording to capture).

## HS2-SPFXPW: separate capture and record-video hotkeys

- **Unit** (`SettingsTests`):
  - `HotkeySlotTests`: per-slot read and write, duplicate rules (each direction, the
    own-problem-first order, a disabled slot blocks nothing), `registrable` for hand-edited
    duplicates, distinct round-tripping Carbon ids, and the record slot's request (video,
    default target and delay)
  - `HotkeyActionTests.recordSlotForEveryPhase`: the record slot's action in every capture phase
  - `CaptureSettingsTests`: the ⌥⇧⌘V default, the stored JSON, legacy settings without
    `recordHotkey`, `null`, and unreadable values
  - `SettingsCommandTests`: `--set-record-hotkey` (set, `none`, bad values), duplicate
    rejection in both directions, allowed swaps, and target-only changes on already-duplicated
    settings
- **App end to end** (`scripts/app-e2e.sh`):
  - defaults
  - both hotkeys persist and register with the system
  - a running menu bar instance holds both (each reports `inUse`)
  - a duplicate exits 2 and isn't saved
  - disabling the record hotkey leaves capture registered
- **Visual QA:** `settings-registered.png` and `settings-in-use.png` show both recorders and
  their status lines.
- **Not covered automatically:** physically pressing the hotkeys. Carbon delivers the press
  to `GlobalHotkeyCenter`, which routes it by `EventHotKeyID.id`, and the routing table
  (`HotkeySlot(carbonID:)`) is unit-tested.

## HS2-6A13WZ: open existing media for annotation

- **Unit** (`MediaImporterTests`, `ImportCommandTests`, on real files):
  - a PNG is copied into a new draft, and the source is left alone
  - a JPEG with EXIF orientation 6 arrives as an upright portrait PNG
  - a real H.264 movie is copied byte for byte, with its size and duration
  - imports append to the current draft in the order given
  - unsupported, corrupt, missing, fake-movie, and empty inputs import nothing and create no
    draft
  - a failed `newReview` import keeps the current draft current
  - error codes and messages
  - `--import` parsing
- **App end to end** (`scripts/app-e2e.sh`):
  - `--import` of a PNG, a JPEG (re-encoded to PNG), and a synthetic recording: sizes, kinds,
    byte-for-byte movie copy, sources untouched, schema-valid `review.json`
  - annotating the imported movie through `--annotate`
  - unsupported, missing, and absent files exit 2 and change nothing
  - `--new-review` starts a fresh draft
- **Not covered automatically:** the open panel and the editor switching to the imported item
  in a live window. Both are thin AppKit glue over the tested importer and
  `AnnotationEditor.show(mediaId:)`.

## HS2-H1RNGK: open media from Finder and editor drops

- **Unit** (`MediaOpenRoutingTests`, `OpenBatchTests`, `OpenMediaCommandTests`):
  - The routing plan:
    - empty input
    - images and movies in the order given, with mixed-case extensions
    - duplicates, including `./` paths and symlinks: the first occurrence wins
    - an unsupported file first, middle, or last rejects the whole batch
    - files with no extension
    - missing files, and folders (including one named `shots.png`)
    - the first problem in the order given is reported
    - a file deleted between two plans
    - non-file URLs
  - Imports through the plan, on real PNGs:
    - Open With goes into the current draft, and a duplicate is imported once
    - a drop goes into an older draft's directory and leaves the current draft current
    - `newReview` is ignored when a draft is named
    - rejected batches, empty batches, and a deleted target draft change nothing and create
      no draft
  - `OpenBatch` transitions: empty adds, start, join, flush, flush again, then empty and refill
  - `--open-media` parsing and its errors
- **App end to end** (`scripts/app-e2e.sh`):
  - the built `Info.plist` declares image and movie document types as Viewer/Alternate
  - `--open-media` with a duplicate imports two items into a new current draft, with
    `editorMediaId` `m1`
  - `--into-draft` adds a movie to an older draft and keeps the newer draft current
  - a text file, a folder, or a missing file exits 2 and changes no draft
- **Not covered automatically:**
  - a real Finder "Open With", or a drop on the Dock icon. Both need Launch Services, which
    the test sandbox blocks.
  - a live drag onto the editor window
  - Both are thin AppKit glue (`AppDelegate`, `EditorHostingView`) over the tested
    `MediaOpenRouting.open`. Manual check: `HS2-2EVZWC`.

## HS2-9Y9DDY: editor zoom and pan

- **Unit** (`CanvasViewportTests`):
  - fit and the 2× cap
  - degenerate sizes
  - actual pixels and back to fit
  - walking every ⌘+/⌘- stop, clamped at both ends (including a fit below 5 %)
  - the anchor pixel stays put while magnifying
  - panning, clamped at all four edges, responding immediately after hitting one
  - a fitted capture doesn't pan
  - single-axis centering
  - a transition walk: zoom → pan to the edge → narrower and wider window → crop → fit → step
  - scale range on 1× and 2× displays
- **App end to end:** `--render-ui-previews` writes `editor-zoomed.png` (300 % with a
  selection) through the real canvas and model.
- **Visual QA:** `editor-zoomed.png` checked by eye. The zoomed image is clipped to the canvas
  (a real bug, found and fixed: since macOS 14 views don't clip by default, so the image
  painted over the tool bar and media strip). Handles and badges stay at screen size, and the
  tool bar shows 300 %.
- **Not covered automatically:** live pinch, scroll, and space-drag events. They are thin
  adapters onto the tested `CanvasViewport` calls.

## HS2-6PV1N3: restore a capture's original after cropping in an earlier session

- **Unit / file-level** (`EditorSessionTests`, real PNGs in a real draft):
  - crop and save, then a later session opens on the original with the crop applied (not
    dirty, no rewrite on save)
  - Restore Original maps the annotation back exactly and makes the file pixel-identical to
    the original
  - undo, then a new crop composes relative to the original (the index records 110,60)
  - a third session restores two sessions of crops in one step, and the index then records
    the full image
  - untrusted originals fall back to the file as found: no index (legacy), unreadable, wrong
    version, size mismatch, outside the original. Cropping them drops the record, and the
    original stays untouched.
  - `priorCropRules`
- **App end to end** (`scripts/app-e2e.sh`):
  - `crops.json` records the first session's crop
  - a third `--annotate` session runs `restore-original`: the PNG is back to the original size
    and pixel-identical (BMP compare), the media size is updated, annotations are mapped back,
    and the schema validates
- (The Reset Crop / Reset Trim label variant was removed by `HS2-71SSJG`; the button is always
  Restore Original.)

## HS2-M8ZFS0: VoiceOver and keyboard-only access to canvas annotations

- **Unit** (`KeyboardAccessTests`):
  - each tool's default shape at the center (exact geometry), selected, back to Select
  - insert → nudge ×5 → undo → undo → redo (one step for the insert, one coalesced nudge run)
  - clamping at the media edges
  - refusals: Select, Crop (with a message), mid-gesture, no media
  - accessibility labels (number across captures, intents, note, "No note.", unknown id)
  - the `insert` script op
- **App end to end** (`scripts/app-e2e.sh`): `--render-ui-previews` sends real `R` and `⏎`
  key events to the canvas and dumps its accessibility tree. The e2e asserts the group's role
  and label, six annotation elements with full labels, the inserted rectangle as the selected
  element, and minimum element frames.
- **Visual QA:** `editor-keyboard-insert.png` shows the inserted rectangle selected at the
  canvas middle.
- **Not covered automatically:** a live VoiceOver session (speech, VO-Space). Element press
  calls the same `select` that clicking does.

## HS2-GBM8JN: video trimming and annotation time ranges

- **State machine** (`VideoTimeTests`), as transition-matrix and adversarial walks:
  - visibility at range ends (inclusive), instants, and whole-clip annotations
  - the playhead clamps and steps, isn't undoable, and resets when the capture changes
  - images refuse the playhead, ranges, and trims
  - selecting a hidden annotation (click, Tab) reveals it
  - hidden annotations can't be clicked or resized
  - new shapes cover the whole clip
  - `setTimeRange` clamps, swaps, is one undo step, and is a no-op when unchanged; duplicate
    keeps the range
  - trim shifts, clamps, and removes ranges (straddling, inside, outside, instants at either
    end), sets `durationMs`, and keeps the playhead's frame
  - undo/redo across trims; trims compose; reset maps back; refused trims (short, whole,
    zero-length) record nothing
  - redo cleared after a new trim; ids stay unique
  - empty-then-refill loops of trim, undo, and reset
  - prior trims start applied, and full-length records count as untrimmed
  - undo across a trim and a capture switch
  - accessibility labels and time formats
  - `OriginalsIndex` trim records round-trip, trust rules, and old indexes without `trims`
- **Session and files** (`VideoTrimSessionTests`, a real 2 s H.264 movie, red then blue):
  - the frame at the playhead, including the clip's end
  - trim → save: the movie's real duration (AVFoundation) matches, the original is kept byte for
    byte, `crops.json` records the trim, and `review.json` validates
  - reopen: the trim is applied and the editor isn't dirty; Restore Original copies the original
    back byte for byte and maps ranges back
  - trims stay undoable after saving and compose from the original
  - an untrusted original is never overwritten
  - scripts with `range`, `time`, and `trim`; render items filtered by the playhead
- **Script parsing** (`VideoScriptParsingTests`): `time`, `range`, `trim`, `reset-trim`, and
  `restore-original`; malformed ops; `time` on an image; `range` on an image annotation
- **App end to end** (`scripts/app-e2e.sh`):
  - `--annotate` on the synthetic recording: a range, an out-of-range annotation, and a trim to
    700 ms
  - checks `durationMs`, shifted ranges, the removal message, the byte-identical
    `originals/capture-2.mov`, the `crops.json` trim record, and the ffprobe duration
    (0.70 s); the schema validates
  - a later session's `restore-original` restores the movie byte for byte, with ranges mapped
    back
  - a `time` step on an image exits 2
- **Visual QA:** `editor-video-timeline`, `editor-video-narrow`, and `editor-video-trimmed`,
  inspected by hand. The hidden instant is dimmed in the list; range bars are numbered and the
  selected one is outlined; Restore Original and the "Trimmed to 2.5 s." status appear after a
  trim.
- **Not covered automatically:** live mouse drags on the scrubber and the timeline buttons.
  These are view code over the unit-tested `setCurrentTime`, `stepTime`, and
  `trimStart`/`EndToPlayhead`; live-window automation is `HS2-HA9TW3`.

## HS2-QNFCR0: play and pause videos in the editor

- **Rules** (`VideoPlaybackTests`, pure): start position (the playhead, or 0 at or near the end),
  player time mapped into the trimmed clip and clamped, and end detection.
- **Real `AVPlayer`** (`VideoPlaybackTests`, the 2 s red-then-blue movie):
  - plays monotonically at about real time, and pausing holds the position
  - the player's frame is the one at its time (red, then blue at the end)
  - it stops at the clip end, and playing again restarts from 0
  - a trimmed clip plays only the kept part (offset into the base movie, ending at the trim end)
  - both output paths show the right frames (red, then blue): the macOS 26+ typed-attributes /
    `pixelBufferAndDisplayTime` path and the pre-26 legacy path, forced on newer hosts
    (HS2-27QR7T)
  - images have no playback; the script `play` op moves the playhead without dirtying the editor,
    and malformed `play` ops are rejected
- **App end to end** (`scripts/app-e2e.sh`): `--annotate` with `play` on the synthetic recording
  advances the reported `currentTimeMs` in real time, stops at the clip end, and exits 2 on an
  image.
- **Visual QA:** `editor-video-playing` (the pause button, and the playhead moved while playing).
- **Not covered automatically:** pressing K and the play button in a live window, and audio
  output. Both call the same `togglePlayback`; live-window automation is `HS2-HA9TW3`.

## HS2-MAH7NK: dragging range ends and trim handles, typed times

- **State machine** (`TimelineDragTests`), as a transition matrix of no drag / range drag /
  trim drag × begin, update, end, cancel, and interruptions:
  - range ends edit live, the playhead follows, and release is exactly one undo step (redo works)
  - dragging past the other end swaps, passes through an instant, and clamps to the clip; the
    bundle still validates
  - instants open either way; a drag back to its start records nothing
  - range handles are refused with no selection, a whole-clip selection, or on an image
  - cancel restores the range and the playhead, and a repeated cancel is harmless
  - every interruption (undo, redo, playhead, step, media switch, select, canvas gesture,
    another drag) restores the pre-drag range; a stale release then does nothing
  - repeated drags, undo, and re-drag refill history and clear redo
  - trim handles preview without trimming, trim on release as one step (with the message),
    keep the minimum length, cancel cleanly, and do nothing when released at the end
  - typed ends drag the other end along, clamp, and refuse unchanged or whole-clip edits
- **Parsing** (`TimelineDragTests`): accepted and rejected typed times, round-trips of
  `TimeFormat.clock`, and the `timeline-drag` script ops (valid and malformed)
- **Hit rules** (`TimelineDragTests`): range grips in the lane, trim brackets on the row, a
  scrub elsewhere, instants by side, and a zero-length clip
- **App end to end** (`scripts/app-e2e.sh`): `--annotate` drags a range end (300–700), cancels a
  start drag (unchanged), drags the end trim handle (message "Trimmed to 0.8 s."), then undoes
  it (duration and movie bytes unchanged); a drag on a whole-clip annotation exits 2
- **Visual QA:** `editor-video-range-drag` and `editor-video-trim-drag` (grips, the dimmed
  cut, the brackets, and the typed From/To fields)
- **Not covered automatically:** live mouse drags and hover cursors on the timeline, and typing
  into the fields in a live window. These are view code over the tested state machine, hit
  test, and parser; live-window automation is `HS2-HA9TW3`.

## HS2-8FTZ09: ← / → frame steps of the last-used timeline target

- **Frame grid** (`FrameStepTests`): steps snap to the movie's frames (30, 25, 10 fps; back
  from inside a frame lands on its start), a trim keeps the movie's grid, and an unknown or
  nonsense rate falls back to 30 fps.
- **Target transition matrix** (`FrameStepTests`): every timeline action (scrub, `,` / `.`,
  trim and range handle drags, typed From/To, Trim Start/End, a frame step) sets its target
  from every starting target; every canvas action (press, draw, keyboard insert, duplicate,
  nudge, another selection, Tab) hands the arrows back to the shape; re-selecting keeps the
  target; undo, redo, and playback-style `setCurrentTime` keep it; a media switch clears it.
- **Fallbacks** (`FrameStepTests`): a range target falls back to the playhead when its
  annotation is deleted, deselected, or made whole-clip (and comes back with undo); a removed
  video or an image leaves no timeline target, where ← / → nudge (⇧: 10 px).
- **Edits** (`FrameStepEditTests`): trim-end and trim-start steps (⇧ ×10) trim, move ranges,
  remove annotations outside, show the new end, step back outward to the original (dropping the
  trim at full length), stop at the 100 ms minimum and the original's ends, and compose with
  earlier mid-frame trims; range ends step, drag the other end along, clamp to the clip, and
  move the playhead. Consecutive steps of one end are one undo step; another end, undo, or
  another edit starts a new one. A step cancels a timeline drag first; images refuse steps.
- **Real movie** (`VideoTrimSessionTests`): the session reads the movie's 10 fps; a scripted
  scrub step and trim-end steps export a 0.9 s movie whose last frame is right.
- **Script** (`FrameStepTests`): `arrow-key` parses `left` / `right` with optional `shift` and
  rejects other keys.
- **App end to end** (`scripts/app-e2e.sh`): `--annotate` steps the playhead one frame, a range
  end one frame back, and the trim end (one undo step restores the duration and the movie).

## HS2-6XMK1J: frame steps for variable-frame-rate movies

- **Grid choice** (`FrameGridTests`): samples on the nominal grid (10 fps, 29.97 fps, ±0.4 ms
  jitter, decode order, a zero-length hold frame at the end) keep the constant rate; irregular
  times, a missing or nonsense nominal rate, or one dropped frame give the real times (rounded
  up to whole ms, 0 and the end added, sub-ms frames merged); fewer than two usable samples
  leave the rate to the caller.
- **Step rule** (`FrameGridTests`): forward and back across irregular gaps, positions between
  samples, ⇧ ×10 across gaps and clamped at both ends, before the start and past the end, an
  empty grid, and the average rate.
- **Editor sequences** (`VariableFrameStepTests`): malformed grids (empty, one boundary,
  unsorted, duplicates) fall back to 30 fps; the playhead visits every real frame then stops;
  trim-end steps over still stretches, down to the minimum and back to the whole movie in one
  undo step; trim-start steps on a mid-frame trim keep the movie's frames (offset clip times,
  clamped at the movie start); range ends snap and clamp; replacing the grid midway (variable →
  constant → variable → unknown → empty → refilled) uses the newest.
- **Real movie** (`VariableFrameRateMovieTests`): an H.264 movie written like a screen
  recording (irregular frames, clock starting at 5 s) reads back as its exact frame starts;
  the same writer at a steady 10 fps steps on the 100 ms grid; a missing file reads nil. In an
  `EditorSession`, scripted arrow keys land on the real frames (showing the right color) and
  trim-end steps trim through them.
- **Visual QA:** `editor-video-frame-step`: a range end grip pressed in place, then ⇧→ and ← sent
  as real key events through the canvas (range to 0:02.90, playhead following).
- **Not covered automatically:** focus in a live window: the canvas taking focus from a time
  field SwiftUI focused on its own, the key monitor redirecting ← / → from an unedited time
  field, and a scrubber press focusing the canvas. Live-window automation is `HS2-HA9TW3`.

## HS2-T0EY2W: microphone narration

- **Writer** (`NarrationTests`, real movies with synthetic 48 kHz LPCM tone buffers on a
  host-like clock):
  - audio that starts before the first frame and runs past the stop: earlier audio is refused,
    the AAC track starts with the video (within 30 ms) and ends at the stop time (within 60 ms)
  - a static screen (one frame, then 3 s of audio): the audio input never stalls
  - regression: audio that ends early no longer shortens the movie (the last frame is held to
    the stop time)
  - narration on but no audio: the movie is still written, without an audio track
  - refused audio: no audio track, the same or an earlier time, after finish (all counted)
  - trimming a narrated movie (`VideoTrim.export`) keeps the audio
  - tone buffers have the right sample count, duration, and format
- **Permission decision** (`NarrationPlan`): the full requested × access × can-prompt matrix.
- **Settings** (`CaptureSettingsTests`, `SettingsCommandTests`): off by default, persists on
  and off, older settings load without it, a wrong type falls back to defaults, the stored JSON,
  and `--set-narration on|off` (bad and missing values rejected).
- **`--capture`**: `--narration` parses for video and is rejected for screenshots.
- **App end to end** (`scripts/app-e2e.sh`):
  - The real backend with `--narration` gives a coherent result for whatever permissions the
    machine has (exit 4/5 writes nothing), without a prompt.
  - A synthetic 2 s narrated region recording reports `narration: true`, and ffprobe shows an
    AAC 48 kHz mono stream whose packets start with the video's (within 60 ms; AAC priming
    makes them start about 44 ms early) and end near 2 s. A plain recording has no audio
    stream.
  - Simulated denied and not-determined microphones exit 4 (`microphonePermissionDenied`, with
    the fix explained), no microphone exits 5, and nothing is written. A plain recording ignores
    the microphone state.
  - Settings: narration is off when fresh, persists on, then off, and a bad value exits 2.
- **Visual QA:** `hud-recording-narration`, `hud-saved-narrated`, and the Settings window's
  Video section (`settings-registered`), inspected by hand.
- **Not covered automatically:** a real microphone (system prompt, real audio sync, unplugging
  mid-recording), the permission alerts, and the menu checkbox. A test must never trigger a real
  Microphone prompt, and clicking menus is `HS2-HA9TW3`. Manual QA is `HS2-2T9RMA`.

## HS2-CRJDJ8: review session flow and submit

- **State machine** (`ReviewSessionTests`):
  - the full matrix of 5 phases (editing, creating, attaching, submitted, failed) × 7 events
    (refresh, edit, set target, submit, advance, succeed, fail): accepted events, and rejected
    ones leaving the session unchanged
  - sequences: empty then refilled; blank title, and a refresh keeping the typed title and
    summary; repeated submit while submitting; failure → edit → retry → submitted (terminal);
    captures removed mid-submission ignored, then applied after a failure down to empty; a
    missing file and an unavailable target blocking, and the target frozen while submitting
  - issue order, messages (annotations by review number), and the capture each one marks; a
    distinct message for every `BundleIssue`
  - `RecentProjects`: dedupe after standardizing, cap of 5, existing-only, persistence, an
    unreadable value, a hand-edited list normalized on load
  - `SubmitCommand` parsing, including escaping `--draft` names
- **Staging and filing** (`DraftSubmitterTests`, a real `ReviewDraftStore` and a faithful fake
  client):
  - a 3-capture draft (image, video, image) is filed with the title trimmed and the summary in
    the ticket; one batch of the three files plus `review.json`; the draft folder and pointer
    are gone and the next capture starts a new draft
  - filing an older draft keeps the current one
  - attach failure → draft and `submission.json` kept → a second failure creates no ticket →
    the retry attaches to the first ticket and cleans up
  - a pending ticket in another store is not reused
  - create failure, missing media, a vanished draft, and an invalid bundle: no ticket, draft
    kept, typed fields saved
  - removing a capture drops its file, annotations, kept original, and crop record; unknown ids
    change nothing; empty then refilled continues numbering
  - `removeSubmitted` refuses the root, its parent, `current`, hidden names, nested and escaping
    paths; removing twice is harmless; an unreadable `submission.json` is ignored
- **Submitter and client** (`ReviewSubmitterTests`, `HotSheetCLIClientTests`): step order and
  resume without `new`; `attachFailed` carries the created ticket; one-line error descriptions;
  the ticket file parsed from `Created <SLUG> (<path>)`, with fallbacks.
- **End to end, Kit** (`HotSheetEndToEndTests.submitsAMultiCaptureDraftAndCleansUp`): a
  3-capture draft with annotations filed by `DraftSubmitter` through the real `hotsheet-cli`;
  the reported ticket file exists; the ticket has all captures, `review.json`, the summary, and
  the annotation sections; `originals/` and `submission.json` are not attached; the draft is
  deleted.
- **End to end, app** (`scripts/app-e2e.sh`, `--submit` against a throwaway store):
  - a synthetic screenshot + video annotated through `--annotate`
  - no draft (exit 2), no store (exit 3), blank title (exit 2 with the issue): no ticket, draft
    unchanged
  - a wrapper CLI failing the first `attach`: exit 5 naming the created ticket, draft and
    `submission.json` kept, title saved; the retry reuses the ticket (exactly one intake
    ticket), deletes the draft, and the ticket has both captures, the summary, `review.json`,
    and the `#2 · insert` section; a second submit finds no draft
- **Visual QA:** `session-ready`, `session-narrow`, `session-submitting`, `session-failed`,
  `session-submitted`, `session-issues`, and `session-empty`, inspected by hand (also checked
  for presence by `scripts/app-e2e.sh`).
- **Not covered automatically:** clicks in the live window (remove confirmation, Change menu,
  Copy Slug, Show Ticket File) and the editor being closed before a removal or submit. These
  are thin view code over the tested model; live-window automation is `HS2-HA9TW3`.


## HS2-2QP0GM: the editor follows captures removed under it

- **State machine** (`EditorMediaSyncTests`), transition matrix of which media goes (the
  showing one, another, the last, all) × what the editor is doing (idle, a selection, a
  gesture, a timeline drag, unsaved edits) × history (undo/redo entries on removed or kept
  media). Every case checks that nothing in the document, saved state, or history refers to the
  removed media and that the bundle validates. Adversarial: repeated syncs, unknown ids,
  remove-everything-then-refill, interleaved adds and removals, and a removed id (and file
  name) reused by a later capture (only drafts from before `numbering.json` can do that).
- **Session and files** (`EditorSessionTests`, real PNGs): a capture removed by
  `ReviewDraftStore.removeMedia` with unsaved edits on it and on another capture, caught up by
  `reload()` or directly by `save()`: no file, original, or annotation comes back, the other
  capture's edit is kept, and undo then save stays consistent. A reused id shows the new file.
- **App end to end** (`scripts/app-e2e.sh`): `--annotate` with `{"op": "remove-media"}` removes
  the showing, cropped capture mid-script; undo/redo and the final save never bring it back,
  and `review.json` validates.
## HS2-6HA14G: Submit Review from the editor

- **Visual QA:** every editor preview from `--render-ui-previews` shows **Submit Review…** at
  the end of the tool bar (wide, narrow, cropped with a long status message, video). The
  previews now paint the window background, so the tool bar is legible in dark mode.
- **Not automated:** the button and ⌘↩ call `EditorWindowController.submitReview`, which saves
  and then opens the existing session window (`ReviewSessionWindowController.show`, covered in
  HS2-CRJDJ8). Clicking it in a live window is part of the live-window automation in `HS2-HA9TW3`.

## HS2-SF72JS: auto-scroll near the canvas edges when zoomed

- **Rule** (`AutoScrollTests`): still in the middle and up to the zone's inner edge; each edge
  reveals what lies past it, corners diagonally; speed grows with depth, matches the formula,
  and is capped far outside; a tiny canvas never scrolls.
- **Viewport** (`AutoScrollTests`, a 5K capture at 400 %):
  - a pointer held at the right edge scrolls monotonically until the media's edge shows, then
    idles, and responds at once the other way
  - the distance is speed × time on the right axis only
  - fitted media, the middle, and zero elapsed time never move
- **Through the editor** (`AutoScrollTests`): a rectangle drawn with the pointer parked at the
  edge grows by exactly the scrolled distance.
- **Visual QA:** `editor-autoscroll` drives the same `EditorModel.autoScrollStep` the canvas
  timer uses, on a 5K mock at 200 %: the box reaches the edge and the capture has scrolled
  under it.
- **Not covered automatically:** the timer under live mouse drags in a window. It is a thin
  loop over the tested step; live-window automation is `HS2-HA9TW3`.

## HS2-5N1GFW: freehand outline smoothing

- **Properties** (`FreehandSmoothingTests`, 40 seeds × an open stroke, a circle, and a square):
  - every output point is within the tolerance of the drawn stroke, and every drawn point is
    within the spacing plus twice the tolerance of the outline (nothing collapses)
  - the point count stays between 3 and the input's count
- **Specific cases:**
  - open strokes keep their exact endpoints; closed outlines don't repeat their start
  - a jittered square keeps all four corners
  - a jittered circle has under 80 % of the radial error after smoothing
  - a straight noisy line becomes its ends plus its widest point
  - degenerate inputs (empty, one, two, identical, sub-spacing, zero tolerance) pass through
- **Through the editor:** the freehand preview equals the committed outline, which is closed and
  has under half the drawn samples. The existing freehand, keyboard, script, and session tests
  still pass with smoothing on.
- **App end to end:** `scripts/app-e2e.sh`'s `--annotate` draws a freehand outline through the
  real editor, and its `review.json` still validates.

## HS2-EZN3NG: narrated videos marked in the bundle and ticket

- **Model** (`ReviewBundleTests`): a media item without `hasAudio` (an older bundle) decodes as
  nil and re-encodes without the field; `false` is normalized away and never written; `true`
  round-trips; the committed example's narrated clip carries it and still matches the encoder.
- **Draft store** (`ReviewDraftStoreTests`): a video capture with audio is written with
  `hasAudio: true`; an image (even if asked) and a silent video are not.
- **Import** (`MediaImporterTests`, `NarrationTests`): a silent movie imports without the field;
  a real narrated movie (AAC track) imports with `hasAudio: true` and its ticket line says
  "with audio".
- **Trim** (`NarrationTests`): trimming a narrated draft video through `EditorSession` keeps
  the audio track and `hasAudio`, and undoing the trim (restoring the original) keeps it too.
- **Ticket text** (`TicketComposerTests`): the example's narrated clip reads
  `(video, 2880×1800, 0:08.000, with audio)` and the listen-or-transcribe note follows the media
  list; without audio, neither appears.
- **Kit Hot Sheet end to end** (`HotSheetEndToEndTests`, real `hotsheet-cli`): the stored
  ticket shows the "with audio" line and note, and the attached `review.json` keeps `hasAudio`;
  a draft with a narrated video submitted by `DraftSubmitter` shows "with audio" too.
- **App end to end** (`scripts/app-e2e.sh`): a synthetic narrated recording writes
  `hasAudio: true` into `review.json` and a plain one omits it; importing the narrated movie
  marks it and the silent "old recording" not; the review-session `--submit` path records a
  narrated clip and the real Hot Sheet ticket's media line says "with audio". `ajv` validates
  every written bundle and the example against the schema.

## HS2-WE30PY: browse, reopen, and discard older drafts

- **Listing** (`DraftListingTests`, a real `ReviewDraftStore` in a temp folder):
  - a missing root, an empty root, and a root holding only an ended pointer list nothing
  - several drafts (current and set aside with `startNew`): newest-edited first, with title,
    capture and annotation counts, `createdAt`, `modifiedAt`, and `isCurrent`. Editing an older
    draft moves it to the top without changing which is current. Equal dates sort by name.
  - a corrupt and a review.json-less folder are listed with their `issue` (titled by folder
    name). Hidden folders, `.DS_Store`, stray files, and a symbolic link to a folder outside
    are skipped. A corrupt current draft is still marked current.
  - a pending `submission.json` names its ticket; a broken one is ignored
  - `summary(of:)` matches the listing entry, refuses the root, and reports a discarded draft
    as `noSuchDraft`
- **Discarding** (transitions and adversarial sequences, into a test trash folder):
  - discard current → the pointer is gone, the folder is in the trash, the list is empty, and
    the next capture starts a fresh draft with `capture-1.png`
  - discard an older draft → the current draft and the next capture's target are unchanged
  - discard twice → the second is `noSuchDraft` and changes nothing
  - a name already in the trash gets a fresh one (`draft-1 2`)
  - corrupt and empty drafts can be discarded (a corrupt current one clears the pointer)
  - refused with `outsideDrafts`, nothing moved: the root, its parent, an outside folder, a
    link to it, a link to a real draft, `current`, a hidden name, `..`, a nested folder, an
    escaping path, and `/`. A plain file inside the root is `noSuchDraft`.
  - a trash that refuses keeps the draft and its pointer
  - an unstandardized path (`sub/../draft-1/`) works
  - `removeSubmitted` now clears the pointer for a corrupt current draft too
  - `DraftTrash.from(environment:)` and `DraftsCommand` parsing (list, discard by name or path,
    missing values)
- **Submitting a non-current draft** keeps the current one (`DraftSubmitterTests.filingAnOlderDraftKeepsTheCurrentOne`).
- **App end to end** (`scripts/app-e2e.sh`, `--drafts` / `--discard-draft` with
  `UXREVIEW_TRASH_DIR`):
  - an empty list, then four drafts (two set aside with `--new-review`, one broken) in order
    with the current one marked, counts, titles, and the broken one's issue; clutter is not listed
  - discard an older draft by name (moved to the trash folder, gone from the list, current
    kept); discarding it again exits 2 `noDraft`
  - discard the current draft by path (pointer gone), then a capture starts a new draft
  - an outside folder, a link, `current`, a hidden name, the drafts folder, and an escaping
    path exit 6 `outsideDrafts` with nothing moved; a missing value exits 2; a broken draft can
    be discarded
- **Visual QA:** `drafts-list`, `drafts-narrow` (the window's minimum width), and `drafts-empty`
  inspected by hand (also checked for presence by `scripts/app-e2e.sh`). The session previews
  show the new **Discard Review…** footer button.
- **Not covered automatically:** clicks in the live windows (the confirmation alert, Open
  Session, Annotate, Show in Finder) and the system Trash itself (`FileManager.trashItem`).
  These are thin view code over the tested store; live-window automation is `HS2-HA9TW3`.

## HS2-N10RZS: Delete Immediately when the Trash refuses a draft

- **Store** (`DraftListingTests`, a real `ReviewDraftStore`, a trash folder inside a plain file
  so it refuses):
  - the Trash refuses → the draft and pointer are kept, `canDeleteInstead` is true → Delete
    Immediately removes the folder and pointer, keeps the older draft → the next capture starts
    a new draft → deleting again is `noSuchDraft`
  - deleting an older draft and a broken one keeps the current draft and never touches the
    trash folder
  - every `outsideDrafts` refusal also holds with `deleteImmediately`
  - a deletion refused part-way (read-only drafts folder) is `deleteFailed`, not offered for
    deletion again; the folder stays listed (broken, still current) and deletes once writable
  - only `trashFailed` offers deletion; `DraftsCommand` parses `--delete` and rejects it
    without `--discard-draft`
- **App end to end** (`scripts/app-e2e.sh`): a refusing `UXREVIEW_TRASH_DIR` exits 5
  `discardFailed` with the draft kept; `--delete` then prints `deleted` with no `trashedTo`,
  the folder is gone, nothing reaches the trash folder, and the list shows only the current
  draft; `--delete` on an outside folder exits 6 with nothing removed; `--drafts --delete`
  exits 2.
- **Visual QA:** `drafts-delete-immediately` (the second confirmation, for a draft with a
  created ticket) from `--render-ui-previews`, inspected by hand.
- **Not covered automatically:** the live alert sequence (Move to Trash → Delete Immediately)
  in a running window; it is thin view code over the tested store (`HS2-HA9TW3`).

## HS2-80CTK8: UX Review windows, Dock icon, app menu bar, short menu bar menu

- **Menus** (`AppMenusTests`):
  - the idle menu bar menu's exact layout (version, Capture Image/Video, Settings, Open UX
    Review, Quit)
  - Capture Image/Video: the default target, Immediate, and Delayed [3 s | 10 s] with spoken
    labels; narration checkbox only under Video, following the next-recording choice
  - hotkey shortcuts shown only on the item a hotkey starts exactly (default delay, an
    unrenderable key)
  - every capture phase replaces the capture submenus (picking, countdown, capturing,
    recording with and without narration, finishing) while the rest stays put
  - the app Capture menu: every target, every delay preset, shortcuts
  - `MenuShortcut` rendering and `AppMenus.clock`
- **Dock presence** (`AppMenusTests.dockIconShowsWhileAnyWindowIsOpen`): a transition walk:
  open, open more, reopen, close one of two, close unknown and already-closed windows, close the
  last, refill.
- **New Review** (`ReviewDraftStoreTests`): an empty draft becomes current and takes the next
  capture (whose context fills the draft's); a second New Review sets the first aside; Start New
  afterwards; drafts are listed.
- **App end to end** (`scripts/app-e2e.sh`): `menus.json` from the real app checks the menu bar
  menu (idle and recording), the Delayed choices, the app menu bar's menus, and File › New Review
  ⌘N, Add Media… ⌘O, Draft Reviews… ⇧⌘O, Submit Review… ⌘↩.
- **Visual QA:** `editor-no-media` (empty New Review window: placeholder and inspector hint),
  `menu-delayed-row-light/-dark` (the segmented Delayed row), and the editor tool bar with **Add
  Media…** at 900 pt (`editor-narrow`), all inspected by hand.
- **Not covered automatically:** the live status item, the real menu bar appearing when the
  app turns regular, ⌘-Tab, Dock clicks and drops, and the menu closing on a Delayed segment.
  These need a person at a Mac (`HS2-PPT7E2`).

## HS2-122ZFZ: dim outside a region while recording it

- **Dim geometry** (`RecordingDimTests`):
  - a region in the middle gives four bands and flips from the display's top-left origin
  - the hole is the even-sized area that is actually recorded
  - regions on corners, full-width strips, and the whole display drop empty bands
  - regions partly off the display are clipped; a region wholly off it gives no dim
  - degenerate holes and bounds, reversed rects, and offset bounds
  - every layout checks that the bands never overlap each other or the hole and, with the
    hole, tile the display
  - the outline stroke lies just outside the hole, and the dim stays slight (alpha 0.25–0.35)
- **Visual QA:** `recording-dim-region.png` from `--render-ui-previews` (presence checked by
  `scripts/app-e2e.sh`, look inspected by hand): the region is clear with a thin red outline,
  and the rest of the test card is slightly dimmed.
- **Not covered automatically:**
  - the live overlay during a real recording: it is click-through, it is absent from the
    movie (filter exclusion plus `sharingType = .none`), and it is torn down on stop, failure,
    and unexpected stop
  - window and screen recordings showing no dim
  These need Screen Recording permission and a live session (`HS2-HA9TW3`).

## HS2-KVMX71: Open UX Review global shortcut

- **Settings** (`SettingsTests`):
  - the ⌥⇧⌘E default, persisted JSON, and loading older settings without the field
  - explicit `null` (disabled), the subscript, and the three defaults distinct and registrable
  - duplicate rules across all three slots
  - `HotkeyAction` for the Open UX Review slot in every phase: open when idle or recording,
    ignored otherwise
  - `--set-open-hotkey` parsing, `none`, duplicate rejection, and a missing value
- **Menu** (`AppMenusTests.openUXReviewShowsItsGlobalShortcut`): the menu bar menu's Open UX Review
  shows the registered shortcut.
- **App end to end** (`scripts/app-e2e.sh`, `--settings`): the default, persistence, real
  registration, a real `inUse` conflict against a running app instance for all three, duplicate
  rejection, and disabling.
- **Visual QA:** `settings-registered` / `settings-in-use` show the third recorder row.
- **Not covered automatically:** pressing ⌥⇧⌘E in another app and seeing the window open (live
  GUI; with `HS2-PPT7E2`).

## HS2-SSM1E7: remove a capture in the editor

- **Unit** (`EditorSessionTests.removingFromTheEditorKeepsUnsavedWorkOnOtherCaptures`): unsaved
  work on the other capture (an annotation and a crop) is saved before removal; the file is
  deleted; the editor shows the neighbor; removing the last capture leaves an empty editor; an
  unknown id throws. `scriptRemoveCaptureSavesBeforeRemoving` covers the `remove-capture` op.
- **App end to end** (`scripts/app-e2e.sh`): `--annotate` with `remove-capture` keeps the
  unsaved rectangle on m2 and deletes `capture-1.png`; the bundle validates.
- **Visual QA:** `editor-annotated` / `editor-video-timeline` show the strip with the ✕ on the
  selected thumbnail (a single-capture video now has the strip too).
- **Not covered automatically:** clicking ✕ or the context menu and the confirmation sheet in a
  live window (`HS2-PPT7E2`-style manual QA).

## HS2-71SSJG: crops and trims are not destructive until submitting

Supersedes the file-rewriting checks listed under HS2-9H7WZ8, HS2-6PV1N3, and HS2-GBM8JN above:
capture files are no longer cropped or trimmed while drafting.

- **Projection** (`DraftEditsTests`): exact maps into and out of a crop (round trip within one
  unit over a grid, beyond 0…10000 when outside) and a trim (exact); outside rules for boxes,
  points, paths, and ranges (edges count as inside); clipping for submission (boxes clipped, an
  arrow pulled to the edge, ranges clamped, outsiders dropped, the result validates);
  `edits.json` round trip, empty → no file, other version and unreadable ignored, and records
  that don't fit their file ignored.
- **Editor** (`ImageCropTests`, `VideoTrimEditTests`, `VideoTimeTests`, `FrameStepTests`,
  `TimelineDragTests`): a crop or trim keeps every annotation, hides the ones outside (not drawn,
  not hit-tested, selection cleared), says how many are hidden, and Restore Original, undo, or
  stepping a trim back out brings them back unchanged; `submissionBundle` validates.
- **Session and files** (`EditorSessionCropTests`, `VideoTrimSessionTests`, real PNGs and movies):
  saving writes `edits.json`, never the capture file; review.json keeps the file's size,
  duration, and coordinates; later sessions open cropped or trimmed and restore without loss;
  five idle sessions never drift; drafts cropped the old way migrate on open (original back in
  place, annotations mapped back, crop in edits.json) and untrusted records leave the file as
  found; a missing image fails submit staging, not the save; a trimmed narrated clip keeps its
  audio when staged.
- **Filing** (`DraftEditsTests.submittingACroppedDraftFilesTheCropAndClippedAnnotations`): the
  attached PNG is the crop, the attached review.json has cropped sizes and clipped annotations,
  and the annotation outside the crop is left out of the ticket.
- **App end to end** (`scripts/app-e2e.sh`): `--annotate` records the crop and trim in
  edits.json with the PNG and movie byte-identical; hidden annotations are flagged `outside` and
  come back with `restore-original`; `--submit` of a cropped and trimmed draft files a 200x120 PNG
  and a 0.8 s clip (ffprobe) with the outsider left out, and the filed review.json validates.
- **Visual QA:** `editor-cropped` (hidden annotations listed dimmed with "Outside the crop · left
  out when submitting"; a shape sticking out is clipped to the image; the shorter status line
  fits).
- **Not covered automatically:** the live inspector and timeline with hidden ranges on a real
  movie (offscreen renders only).

## HS2-E3001H: add a review to an existing ticket

- **Reference and CLI parsing** (`TicketReferenceTests`, `HotSheetTicketParsingTests`,
  `ExistingTicketCLITests`, a fake runner replaying output captured from the real CLI):
  - slugs in any case, a slug with no digit, ULIDs, ticket file paths, links, `hotsheet-cli ls`
    lines, and text around a slug; text with no ticket (including words like `ux-review`) is
    refused
  - `show` front matter: plain, single-quoted, and double-quoted titles; nested lists and the body
    are not read as fields; `deleted` / `moved` refuse reviews; the ticket file path from the ULID
  - `show` exit 1 "no ticket matching" is nil; other failures and unreadable output throw
  - `attach` stored names from `Durable attachment id` lines (renamed `review (3).json`, a name
    with a backtick), and a fallback to the file names
  - `edit --note-file`: the note's exact text reaches the file, the file is removed afterwards, and
    a failure carries stderr
  - `--to-ticket` parsing: a value, no slug in it, a missing value
- **Note** (`ExistingTicketNoteTests`): title, counts, and canonical `review.json` line; summary,
  media, and annotation sections one heading level deeper; no intake instructions; renamed
  attachments cited by their stored names (with the draft name); the intake body unchanged by the
  shared sections; code spans fenced around backticks.
- **State machine** (`ExistingTicketSessionTests`):
  - the lookup matrix: 7 states (empty, unrecognized, looking, found, not found, failed, no store)
    × 10 inputs (clear, junk, the same slug, the same slug in another case, another slug, the
    current result, a stale result, another store, no store, the same store)
  - the issue and message for each state; only a found, open ticket can be submitted to; a deleted
    one is refused
  - every phase × the destination events (frozen while submitting and after)
  - sequences: switching back and forth keeps the typed ticket and its lookup; the first submit
    step per destination; a result for a slug edited meanwhile, and a repeated result, are
    ignored; emptied then refilled; a project change looks up again and drops the old store's
    answer; after a failure the ticket can still change
- **Staging and filing** (`ExistingTicketSubmitterTests`, a real `ReviewDraftStore` and the fake
  client, which renames colliding names like the real CLI):
  - attach then note: one batch with the usual label, purpose, and files; the note cites
    `review (2).json`; no ticket created; the draft deleted; the result names the existing ticket
  - a failed note keeps the draft and `submission.json` with the stored names (`--drafts` /
    the Draft Reviews row show it); a second failure and the successful retry write only the note,
    citing the first attach's names: one batch, one note
  - a failed attach writes no record; the retry starts over
  - records reused only for the same kind, ticket, and store; old records without names decode
  - missing media writes nothing
- **End to end, Kit** (`HotSheetEndToEndTests.addsADraftToAnExistingTicket`): a real ticket that
  already has `capture-1.png` and `review.json`; the lookup reads a quoted title and the ticket
  file; a missing slug is nil; the first note fails (a wrapper runner), the retry adds it; the
  ticket keeps its body and has exactly one note citing `capture-1 (2).png` and
  `review (2).json`, one batch of three files, human actor, and no new ticket.
- **End to end, app** (`scripts/app-e2e.sh`, `--submit --to-ticket` against a throwaway store):
  no slug (exit 2 `invalidArguments`); an unknown ticket (exit 2, "No ticket HS-NOPE00 in
  subproj.hs2."); a wrapper CLI failing the first `edit`: exit 5 with `attachedTo`, the record
  with stored names, `--drafts` showing `pendingNoteOnly`; the retry adds the note (a lowercase,
  padded slug first); the ticket has one note, one batch, the renamed capture, and no new ticket.
- **Visual QA:** `session-existing-looking`, `-found`, `-narrow`, `-not-found`, `-closed`,
  `-failed`, and `-submitted`, inspected by hand (also checked for presence by
  `scripts/app-e2e.sh`). `session-ready` shows the Ticket section below the fold at 720 pt; the
  form scrolls.
- **Not covered automatically:** typing into the live field (the 300 ms lookup debounce in
  `ReviewSessionModel`) and the segmented control's clicks; thin view code over the tested
  session (`HS2-HA9TW3`).

## HS2-QNWMKF: resume an interrupted (non-atomic) attach without duplicates

- **CLI transport** (`ExistingTicketTests.aPartialAttachReportsWhatGotIn`, `FakeRunner` replaying
  the real CLI's partial output: one file's lines, `Error: …`, exit 1): `attachIncomplete` with
  the stored names printed so far; `--batch-id` passed through; a failure before any file stays
  `commandFailed`; the one-line description.
- **Submitter transitions** (`PartialAttachTests`, `FakeHotSheetClient` stopping after N files
  like the CLI):
  - new ticket: partial → partial → nothing → success. Each retry sends only the missing files
    with the same batch id; the record grows, is unchanged by a failure that attaches nothing,
    and the end result is one ticket and each file once. The Draft Reviews flags are checked.
  - existing ticket: partial (renamed stored names kept) → rest attached, note fails → note only,
    citing the names from the interrupted attach; one batch id
  - records don't cross: an existing-ticket partial isn't reused for a new ticket and vice
    versa; a partial in another store starts over
  - older `submission.json` records decode (`toExistingTicket` absent; `attachedNames` alone
    still marks an existing ticket)
- **End to end with the real CLI** (`HotSheetEndToEndTests.aPartialAttachResumesWithoutDuplicates`):
  an unreadable `capture-2.mov` (mode 000) stops the real `attach` after `capture-1.png`; after
  restoring it, Try Again files the rest. The ticket has each file once, all in one batch, then
  the same for adding to that ticket (renamed files in a second batch, exactly one note).
- **Not covered automatically:** the session window's Try Again text for a partial attach (thin
  view code over `SubmissionFailure.partlyAttached`).

## HS2-DX2D41: window picker hover on multi-display setups

- **Unit** (`RegionGeometryTests.eventPointsUseTheEventsOwnWindow`): a window-relative point
  converts through the frame of the event's own overlay (the secondary display at x 1440, y −180
  → global (1540, −130), on display 1), the same location on the primary overlay stays on display
  0, and an event without a window uses the global mouse location.
- **Not covered automatically:** a live pointer on two physical displays; the remaining
  overlay code is a one-line call into the tested function. The manual check belongs with
  `HS2-3JD5PS`.

## HS2-64P9DT: Submit Review shows captures as they will be filed

- **Unit** (`SubmissionPreviewTests`): no edits shows the draft as is; a crop and a trim give
  the cropped size, trimmed length, filed and left-out counts, and the "outside the crop / trim"
  notes; edits that don't apply (unknown file, full-size crop, too-long trim) are ignored like
  submitting; plural and empty reviews. Image thumbnails show only the crop (colour checked),
  scaled down but never up; a crop outside the image gives none.
- **Encoding** (`EncodingTests.SubmissionThumbnailTests`): a real H.264 movie's thumbnail is red
  at 0 and blue at 1.5 s (the trim start).
- **Visual QA:** `session-edited` (`--render-ui-previews`, a cropped screenshot and a trimmed
  movie each leaving one annotation out), inspected by hand and checked for presence by
  `scripts/app-e2e.sh`.

## HS2-00TXV6: add only part of a review to an existing ticket

- **Selection transitions** (`ReviewSelectionTests`): leave out a capture (its annotations go
  too) or one annotation; repeated toggles are harmless; re-including a capture keeps other
  choices; including an annotation of a left-out capture brings it back with only that one;
  everything out and back; pruning to the draft; later captures are included.
- **Session**: "Choose at least one capture to add." only for an existing ticket; a refresh
  prunes; no change while submitting. `--exclude` parsing and mapping (unknown ids, missing
  `--to-ticket`, empty list).
- **Submitter** (`PartialReviewSubmitterTests`, fake client): only the chosen files and
  annotations are attached, the note numbers them #1, #2; the draft keeps an unsent capture and
  a sent capture with an unsent annotation, and drops the rest; then the rest files and deletes
  the draft. A selection of everything deletes the draft. A failed note records the selection;
  the retry sends that part even when asked for another, and the draft's own `review.json` is
  untouched meanwhile. Nothing selected sends nothing.
- **Real CLI** (`HotSheetEndToEndTests.addsOnlyTheChosenPartToAnExistingTicket`): the ticket has
  only `capture-1.png` and a `review.json` with the chosen annotation (schema-valid), the note
  has #1 only, and the draft keeps the rest.
- **App end to end** (`scripts/app-e2e.sh`): `--exclude m2` adds one capture, reports
  `remainingCaptures: 1`, and the draft keeps only `capture-2`; excluding everything and an
  unknown id are refused.
- **Visual QA:** `session-existing-selection` (checklist open, one capture and one annotation
  left out), inspected by hand.
- **Not covered automatically:** clicking the checkboxes in a live window (thin bindings over
  the tested `ReviewSelection`).

## HS2-8NATQR: switch Screen / Window / Region from inside the picker

- **Unit** (`PickerKeysTests`): key codes; the key × mode × dragging matrix (Esc cancels and
  Return picks the display everywhere; Space toggles region ⇄ window, ignored mid-drag and in
  display mode); a press sequence; the hints name the keys.
- **Visual QA:** `overlay-region-hint` and the new `overlay-window-hint` (`--render-ui-previews`,
  presence checked by `scripts/app-e2e.sh`).
- **Not covered automatically:** pressing keys in the live overlays (they can't be driven
  headless). The session code is a thin switch over `PickerKeys.action`; the manual check is
  in `HS2-3JD5PS`.

## HS2-3SVGZ3: offer to trash a ticket left behind by a failed New ticket try

- **Unit** (`AbandonedTicketTests`): after a failed (or partly attached) New ticket try, adding
  to an existing ticket names the created ticket and trashes nothing; a record of the existing
  ticket itself, no record, or a record in another store names none; `moveToTrash` runs
  `edit --status=deleted` with the reviewer's actor.
- **Real CLI** (`HotSheetEndToEndTests.anAbandonedTicketCanBeTrashed`): an unreadable capture
  fails the New ticket attach, the existing-ticket submission names the created ticket (still
  `not_started`), and `moveToTrash` sets it to `deleted`.
- **App end to end** (`scripts/app-e2e.sh`): `--submit --to-ticket` reports `abandonedTicket`
  and leaves that ticket untouched.
- **Visual QA:** `session-existing-abandoned` (`--render-ui-previews`), inspected by hand.
- **Not covered automatically:** clicking Move to Trash and its confirmation in a live window
  (`ReviewSessionModel.trashAbandonedTicket` runs the tested `moveToTrash` off the main thread).
