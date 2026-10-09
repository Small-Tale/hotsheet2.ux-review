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
  - the picker's target (`HS2-E14X2P`): the frontmost visible window whoever owns it, so UX
    Review's own windows on top are picked; capture chrome (by window id) is skipped at any
    layer and never hides what is under it
  - which of UX Review's own windows display and region captures keep: all but capture chrome
    (HS2-63B0PJ), the same split the picker uses; the real ScreenCaptureKit output is manual QA
    (`HS2-JG04GX`)
- **Recording window exceptions** (`RecordingWindowExceptionsTests`, HS2-XT5K63): when a
  running display recording's filter must be updated.
  - transition matrix: own windows opening, closing, reopening (same or new id), chrome
    appearing and going away, other apps' windows, reordering, and no change (no update)
  - one update in flight at a time; changes made, or undone, during it are caught up after
  - failed updates apply nothing, are retried up to 3 times for the same set, then given up
    until the set changes; a success resets the count
  - a realistic multi-step recording session
  - not covered automatically: `OwnWindowFollower` updating a live `SCStream`, which needs
    Screen Recording permission (manual live check `HS2-3SE1KX`)
- **Live window list** (`LiveWindowListTests`, HS2-VJ8VE8 regression): the window pick re-reads
  the window list while it runs.
  - transition matrix: no list / fresh / stale × pointer move, timer, click, mode switch; only a
    pointer move over a fresh list reuses it
  - pointer bursts are throttled; re-reading an unchanged layout reports no change; a clock that
    steps backwards counts as stale
  - the pick follows windows that move, resize, reorder, open, and close (empty → refill),
    including a click inside the pointer throttle window
  - floating windows still win, UX Review's own windows are picked, and chrome (overlay, an
    app-level dim) is skipped on a refreshed list, through open → close → refill
  - not covered automatically: the live timer and pointer refresh against real windows
    (`HS2-JG04GX`)
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
  - real `UserDefaults` suites, through `TestSupport.withTemporaryDefaults`: the suite name is an
    absolute path in a temporary folder, so its plist is written there and removed with the
    folder, never to ~/Library/Preferences (HS2-1AD1FJ; a named suite's empty plist was written
    again by cfprefsd after the test process exited, however the test cleaned up)
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
  - the suite is `$TMP/defaults` (an absolute path), so it is removed with the run's temporary
    folder; the run asserts its plist is there and `defaults domains` doesn't list it, so no
    `uxreview-e2e-<pid>` domain is left in ~/Library/Preferences (HS2-1AD1FJ)
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
  - intent chip clicks (`IntentClickTests`): plain click selects one, ⌘ / ⇧ toggles, over every
    shape × intent × prior set; no-op clicks leave no history; undo/redo; script `modifier`
- **Crop and geometry** (`ImageCropTests`, `ShapeGeometryTests`):
  - snapping
  - boxes clipped, points pulled to the edge, outsiders removed
  - a second crop replaces the first (relative to the original), undo, and redo; refused crops
    (tiny, whole, video)
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
  - `--annotate` on synthetic screenshot + video drafts draws every shape with notes, intents
    (a plain intent click selects one, ⌘ adds), undo/redo, and delete+undo
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
  - undo, then a new crop replaces it, relative to the original (the index records 110,60)
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
  - the video output shows the right frames (red, then blue) through the typed-attributes /
    `pixelBufferAndDisplayTime` path (HS2-27QR7T; the pre-26 fallback was dropped with the
    macOS 26 deployment target, HS2-6ANG9S)
  - images have no playback; the script `play` op moves the playhead without dirtying the editor,
    and malformed `play` ops are rejected
- **App end to end** (`scripts/app-e2e.sh`): `--annotate` with `play` on the synthetic recording
  advances the reported `currentTimeMs` in real time, stops at the clip end, and exits 2 on an
  image. The step's time counts from when the player starts moving and the check's floor is a
  quarter of the step, so it holds under heavy machine load (HS2-5J2SGB).
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

## HS2-6XMK1J, HS2-BADS0F: frame steps for variable-frame-rate movies

`HS2-6XMK1J` stepped through a variable-rate movie's real samples; `HS2-BADS0F` replaced that
with a uniform grid at the movie's expected rate.

- **Expected rate** (`FrameGridTests`): a recorded rate wins (also without samples; a nonsense
  one is ignored); samples on the nominal grid (10, 29.97, and 5 fps, ±0.4 ms jitter, decode
  order, a zero-length hold frame at the end) keep the nominal rate exactly; variable-rate
  movies (jittery 30 and 60 fps screen recordings with still stretches, a dropped frame, one odd
  short gap, the irregular burst movie, a 24 fps interval, a 37 fps one, a 1 ms one capped at
  240) give their snapped interval with or without a nominal rate; frames seconds apart give
  nil (the editor's 30 fps); fewer than two usable samples, no sample table, or sub-0.5 ms gaps
  fall back to the nominal rate, and a nonsense nominal rate to nil. Snapping picks the nearest
  standard rate by ratio (29.9 → 29.97, 55 → 59.94) and leaves 72 alone.
- **Step rule** (`FrameGridTests`): the uniform grid forward and back, inside a still stretch,
  ⇧ ×10, past the start (callers clamp), and which rates are valid.
- **Editor sequences** (`VariableFrameStepTests`): at 30 fps the playhead steps one expected
  frame out of a still stretch, ⇧ ten (1/3 s), and clamps at both ends; trim-end steps go down
  and back to the whole movie; a range end steps; replacing the rate midway (30 → 10 →
  unknown → nonsense → 25) uses the newest.
- **Real movies** (`VariableFrameRateMovieTests`): a `VideoFileWriter` movie with irregular
  frames reads its recorded 30 fps, and a steady one its recorded 10; another writer's jittery
  30 fps-capped screen recording (plain `AVAssetWriter`, no metadata, host-like clock) reads
  30; a plain constant 25 fps movie reads 25; a missing file reads nil. In an `EditorSession`,
  scripted arrow keys step one 30 fps frame inside a still stretch (showing the right color),
  ⇧→ ten frames, and trim-end steps trim on the uniform grid.
- **Edit lists** (`EditListFrameRateTests`, `HS2-Z4YPV1`, `AVMutableMovie` reference movies
  over a plain 10 fps source): two edits, the second starting inside a frame, map each sample
  to the time it shows (samples outside the edits left out) and still read 10 fps (counting the
  edit start as a frame time read 20); an edit slowed to half speed spreads its frames 200 ms
  apart and still reads 10 fps. `FrameGridTests` also pins that times within 0.5 ms count once,
  so a duplicate time no longer breaks the constant-rate check.
- **App end to end** (`scripts/app-e2e.sh`, `HS2-Z4YPV1`): a synthetic region recording whose
  screen stops changing after 0.4 s (`UXREVIEW_SYNTHETIC_STILL_AFTER_MS`; with ffprobe, at most
  10 recorded frames in 2 s) steps → from 1.0 s to 1.1 s, and ← then ⇧→ to 1.9 s, inside the
  still stretch: one recorded-rate (10 fps) frame, not the next recorded sample. The estimate
  for movies without a recorded rate is covered by the real-movie tests above, not the app.
- **Background loading** (`VariableFrameRateMovieTests`, `HS2-F999CM`, real movies on the main
  actor): with `.inBackground` a session steps at 30 fps until the movie's recorded 10 fps
  arrives, then steps on the new grid from where it was; a capture picked up later loads in the
  background too, without touching the first one's rate; a read for a capture removed before it
  arrives is abandoned and never applied; the default `.immediately` has the rate on open.
- **Visual QA:** `editor-video-frame-step`: a range end grip pressed in place, then ⇧→ and ← sent
  as real key events through the canvas (range to 0:02.90, playhead following).
- **Not covered automatically:** focus in a live window: the canvas taking focus from a time
  field SwiftUI focused on its own, the key monitor redirecting ← / → from an unedited time
  field, and a scrubber press focusing the canvas; and the editor window opening its session
  with `.inBackground` (the session side is tested above). Live-window automation is
  `HS2-HA9TW3`.

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

## HS2-S4GA06: pointer and clicks in recordings

- **Settings** (`CaptureSettingsTests`, `SettingsCommandTests`):
  - defaults: pointer on, clicks off
  - all four pointer × clicks combinations persist and map to `RecordingPointer`
  - older settings without the fields load with the defaults; `null` takes the default; a
    wrong type falls back to all defaults; the stored JSON
  - `--set-show-pointer` / `--set-show-clicks on|off` (any case), each leaving the other
    alone; bad and missing values rejected
- **App end to end** (`scripts/app-e2e.sh`):
  - fresh settings report pointer on and clicks off
  - a synthetic headless recording reports the saved `pointer` options before and after
    `--set-show-pointer off --set-show-clicks on`; a screenshot reports none
  - bad values exit 2
- **Visual QA:** the Settings window's Video section (`settings-registered`) shows both toggles.
- **Not covered automatically:** that ScreenCaptureKit really draws the pointer and click rings
  into the movie. That needs Screen Recording permission and a live session (`HS2-JG04GX`).

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
  - Capture Image/Video and the narration checkbox following the next-recording choice (the
    submenus with Immediate and Delayed [3 s | 10 s] were replaced by the Delay row in
    `HS2-WC6JSH`, below)
  - hotkey shortcuts shown only on the item a hotkey starts exactly (default delay, an
    unrenderable key)
  - every capture phase replaces the capture rows (picking, countdown, capturing,
    recording with and without narration, finishing) while the rest stays put
  - `MenuShortcut` rendering and `AppMenus.clock`
- **Dock presence** (`AppMenusTests.dockIconShowsWhileAnyWindowIsOpen`): a transition walk:
  open, open more, reopen, close one of two, close unknown and already-closed windows, close the
  last, refill.
- **New Review** (`ReviewDraftStoreTests`): an empty draft becomes current and takes the next
  capture (whose context fills the draft's); a second New Review sets the first aside; Start New
  afterwards; drafts are listed.
- **App end to end** (`scripts/app-e2e.sh`): `menus.json` from the real app checks the menu bar
  menu (idle and recording), the app menu bar's menus, and File › New Review
  ⌘N, Open… ⌘O, Open Recent, Close ⌘W, Save… ⌘S, Add Media… ⇧⌘O, Submit Review… ⌘↩ (HS2-BKWZ5N).
- **Visual QA:** `editor-no-media` (empty New Review window: placeholder and inspector hint),
  `menu-delay-row-light/-dark` (the Delay row, `HS2-WC6JSH`), and the editor tool bar with **Add
  Media…** at 900 pt (`editor-narrow`), all inspected by hand.
- **Not covered automatically:** the live status item, the real menu bar appearing when the
  app turns regular, ⌘-Tab, and Dock clicks and drops.
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
    movie (capture chrome, left out by the filter), and it is torn down on stop, failure,
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

## HS2-0KFBZG: product name

- **Unit** (`ProductNameTests`): the full name is Hot Sheet 2 UX Review and ends with the short
  name UX Review.
- **Not covered automatically:** the About panel's title in a running app (one AppKit call with
  `ProductName.full`); the app menu's About item is in the `menus.json` e2e dump.

## HS2-W62GWS: Capture [Screen | Window | Region] in the menu bar menu

- **Unit** (`AppMenusTests`): the idle layout puts the **Capture** picker above Capture Image;
  the picker lists Screen, Window, Region with `setCaptureTarget` commands and selects the
  default target; a walk over target changes (including a repeat and a revisit) keeps the
  selection on the new target while kind and delay stay put; every running phase hides the
  picker. (Since `HS2-WC6JSH`, the capture items read the target when chosen; see below.)
- **App end to end** (`scripts/app-e2e.sh`): `menus.json` checks the picker row (choices and
  selected Region) and `statusMenuAfterPicking` (below).
- **Visual QA:** `menu-capture-target-row-light/-dark` (`--render-ui-previews`), inspected by
  hand.
- **Not covered automatically:** clicking a segment in the live status menu and the Settings
  window following it (`AppDelegate.perform` → `SettingsModel.update`); needs a person at a Mac.

## HS2-WC6JSH: Delay [None | 3 s | 10 s] in the menu bar menu; no capture submenus

- **Unit** (`AppMenusTests`):
  - the idle layout: Capture and Delay pickers, plain Capture Image / Capture Video items
    (`captureDefault` commands, no submenus), the narration checkbox, then Settings…
  - the Delay picker lists None, 3 s, 10 s with `setCaptureDelay` commands and spoken labels,
    and selects the default delay
  - a Settings-only default (5 s, 60 s) shows as its own selected segment, in order, and goes
    away when a listed delay is chosen (empty-then-refill walk)
  - an interleaved, repeated walk of target and delay changes keeps both selections on the
    settings and the kind unchanged, with the shortcuts on the item each hotkey starts exactly
  - shortcuts at every default delay, and none for an unrenderable or unset hotkey
  - every running phase replaces exactly the capture rows
- **App end to end** (`scripts/app-e2e.sh`): `menus.json` checks the idle menu's titles and
  shortcuts, the Delay row (choices and selected None), no submenus, and
  `statusMenuAfterPicking`: in an open menu built like the status item's, choosing Window and
  3 s selects both, and then choosing Capture Image and Capture Video (real menu item actions)
  starts "Screenshot of Window after 3 s" and "Video of Window after 3 s".
- **Visual QA:** `menu-delay-row-light/-dark` (`--render-ui-previews`), inspected by hand.
- **Not covered automatically:** clicking the live status menu (needs a person at a Mac).

## HS2-T4RS7M: picker rows line up with ordinary menu items

- **App end to end** (`scripts/app-e2e.sh`): `menus.json` reports each picker row's
  `titleInset`: 16 in the idle menu and in `statusMenuNarrating` (Narrate is a switch row since
  `HS2-JBWPP5`, so there is no checkmark column).
- **Not covered automatically:** the measured AppKit offsets themselves (16 / 18 pt, from the
  reviewer's screenshots on the ticket); a person confirmed the live menu on `HS2-RG3JXC`.

## HS2-JBWPP5: flipping Narrate keeps the menu open

- **Unit** (`AppMenusTests`): the status menu carries Narrate as a
  `.toggle` entry that follows the next-recording choice.
- **App end to end** (`scripts/app-e2e.sh`): in `menus.json`, the status menu's Narrate row is a
  switch row (`toggle`), off when idle and on in `statusMenuNarrating`, its title at 16 pt. `statusMenuAfterPicking` flips it in an open menu built like
  the status item's: the row shows on, the menu keeps all 12 rows, and the command runs between
  the picker choices and the captures.
- **Visual QA:** `menu-narrate-row-off/-on-light/-dark` (`--render-ui-previews`), inspected by hand.
- **Not covered automatically:** that the live menu stays open when the switch is clicked
  (AppKit keeps menus open for clicks in item views, as for the picker rows); needs a person at a Mac.

## HS2-JHTAZM: shapes crossing a crop edge are clipped exactly to the media

- **Unit, pixel-exact** (`AnnotationClipTests`): `AnnotationRenderer` draws into a canvas-like
  bitmap (dark margin around the media rect).
  - The reported arrow leaving the media on the right leaves every canvas pixel past the edge
    untouched, with its shaft drawn up to the edge.
  - Rects, arrows, a freehand, and a strike crossing every edge at a thick stroke touch nothing
    outside the media except their badges.
  - A full-frame rect keeps the inner half of its stroke.
  - All three failed before the fix (the old clip had two stroke widths of slack).
- **Visual QA:** `editor-video-cropped` and `editor-cropped` (`--render-ui-previews`), inspected by hand.

## HS2-0TQ6RP: select several captures; ⌘⌫ removes them without asking

- **Unit, transition matrix** (`MediaSelectionTests`): a long walk over plain, ⌘-, and ⇧-clicks
  (repeats, ranges both ways, ⌘-clicking the shown capture out with and without a selected
  capture after it, the last selected capture, unknown ids); the editor moving away by other
  means collapses the selection and the next click starts from what is shown; removals of a
  selected, an unselected, the shown, and every capture, then a refill reusing ids; removal
  targets (in the selection, outside it, none, unknown); an empty strip; the sheet's words for
  one and several captures.
- **Unit, real files** (`EditorSessionTests`): removing a ⇧/⌘-built selection saves unsaved work
  on the captures that stay, deletes exactly the selected files, shows the nearest remaining
  capture alone, and undo can't bring them back; removing every capture leaves the empty draft;
  an unknown id removes nothing and repeats count once; the `click-media` and
  `remove-selected-captures` script ops parse (a bad modifier fails) and run; selecting an
  annotation or showing another capture collapses the selection.
- **App end to end** (`scripts/app-e2e.sh`): `--annotate` on four captures builds a selection with
  click, ⇧-click, ⌘-click, removes it with `remove-selected-captures`, and checks review.json,
  the files, the shown capture and `selectedMediaIds`; a second script removes every capture.
  `menus.json` checks Edit's **Remove Capture from Review…** and **Remove Capture Now ⌘⌫**.
- **Visual QA:** `editor-multi-select` (`--render-ui-previews`), inspected by hand.
- **Not covered automatically:** real ⌘/⇧ mouse clicks in the SwiftUI strip
  (`NSEvent.modifierFlags`), the confirmation sheet, menu titles naming the count, and ⌘⌫ being
  passed to the note field while it edits text; needs a person at a Mac.

## HS2-PT8PM6: downscale images and videos for AI when filing

- **Sizing** (`MediaScalingTests`):
  - Claude's rule against the Vision docs' examples on both tiers, including the token-limited
    portrait 1075×1520 → 924×1307 on the standard tier and 3840×2160 → 2576×1449 on the
    high-resolution tier. For 2000×1500, the docs' table says 1269×952, but their reference
    implementation (which this follows) gives 1270×952, also 1564 tokens.
  - A sweep: every result fits both limits, keeps the aspect ratio within rounding, and never grows.
  - The 2048 px longest-edge rule (fallback).
  - OpenAI's patch rule for Codex (`HS2-Q0R78W`): the guide's 2048×2048 → 1600×1600, Mac
    display sizes, edge-only and fitting cases, and a sweep: every result fits 2048 px and 2,500
    patches, never grows, and is left alone when sized again (the API won't resize it).
  - Never scaling up, and empty sizes.
  - Movie sizes rounded down to even sides, with a fitting movie left alone.
- **Choosing the target** (`MediaScalingTests`):
  - Claude model → tier for aliases (`opus`, `sonnet`, `fable`, `mythos`, `haiku`, `opus[1m]`,
    `opusplan`), full and Bedrock-style ids, old `claude-3-5-…` ids, date suffixes, and unknown
    models.
  - Recognising Claude model ids under any tool (`HS2-8G9F3R`): `claude-…`, antigravity's
    `-thinking` ids, `anthropic/` and OpenRouter paths, Bedrock prefixes, dotted and `@date`
    versions; bare aliases, `claude-instant`, and ids that merely contain `claude-` are not.
  - Tool → target, and a Claude model picking Claude's rule under antigravity, opencode, and codex.
  - Parsing the CLI's JSON.
- **Detection** (`MediaScalingTests`, fake process runner):
  - `ai-settings get --json` arguments, with the inherited AI actor scrubbed.
  - An old CLI (exit 2), a non-store, plain-text, or empty output all fall back to 2048 px.
  - Fake clients that can't tell, or that throw, fall back too.
- **Bundle and preview** (`MediaScalingTests`):
  - Scaling changes only media sizes, not annotations, and the bundle stays valid.
  - The Submit Review list text: "1996×1248 scaled for Codex", "… cropped, scaled for Claude",
    and unscaled captures unchanged.
- **Settings** (`SettingsTests`):
  - On by default.
  - Legacy JSON without the field turns it on; `false`, `null`, and a wrong type.
  - `--set-downscale on|off` and bad values.
  - `--submit --downscale on|off` and bad values.
  - The stored JSON includes the field.
- **Real files** (`EncodingTests.SubmissionScalingTests`):
  - A 3000×2000 PNG is filed at 1920×1280 for Codex, with the draft byte-identical and still full size.
  - A crop, then Claude's standard tier, gives annotations identical to the unscaled crop.
  - A capture that fits files the draft itself.
  - A real H.264 movie is trimmed and scaled in one export to 100×56 (even), trimmed within a
    frame and showing the trimmed part; scale alone keeps the full length.
  - `DraftSubmitter` attaches the scaled PNG with a `review.json` whose sizes match and whose
    annotation is unchanged. It reports `scaledCaptures` / `scaledFor`, and without a scale it
    files full size.
- **App e2e** (`scripts/app-e2e.sh`, "downscale for AI when filing"):
  - The setting's default, persistence, and a bad value.
  - A 3840×2400 imported image and a synthetic 1400×900-point recording are filed into a
    throwaway store through a wrapper CLI reporting Claude Haiku. The PNG, the movie (with
    `ffprobe`), and the filed `review.json` match the docs' standard-tier sizes (computed by the
    reference rule in node), with even movie sides, and the annotations are the draft's.
  - Codex gives 1996×1248 (the 2,500-patch budget, `HS2-Q0R78W`); a CLI without `ai-settings`
    gives 2048×1280.
  - opencode running `anthropic/claude-opus-4-7` gets Claude's high-resolution tier (`HS2-8G9F3R`).
  - `--downscale off` and the setting off file 3840×2400.
- **Visual QA:** the `session-*` renders (`--render-ui-previews`) show the mock captures scaled
  for Claude's standard tier (the 1600×1000 mock reads "1389×868 scaled for Claude").
- The Settings toggle, a live Submit Review window following it, and rotated movies are covered
  by `HS2-ZMDH5D` (below).

## HS2-4N722Z: the Crop tool shows the original and adjusts one crop

- **Unit** (`CropToolTests`): the Crop tool shows the original (canvas frame, origin, overlay,
  hint) and other tools the crop (fit frame, hit testing, drawing in crop pixels); videos and an
  empty review never show it; which edge, corner, or inside a press grabs (uncropped, cropped,
  tiny crops); moves by whole pixels clamped to the capture, resizes that never flip or go under
  8 px, one undo step each and full undo/redo walks; a new rectangle replaces the crop, clicks
  and moves by nothing do nothing; a crop out to the whole capture removes it; Esc, undo, redo,
  other media, another tool, or a new press mid-drag (move, resize, new) leave nothing behind;
  Restore Original and undo while the tool is chosen; each capture keeps its own crop across
  switches and undo jumps back to it. A seeded random walk (12 × 400 steps of tool switches,
  crop drags, cancelled drags, undo, redo, Restore Original, switching captures) checks the
  canvas-space rules and that no annotation ever drifts from where it was drawn, reaches every
  tool × crop × change combination, and undoes back to uncropped.
- **Unit** (`CanvasViewportTests`): `reframe` keeps the zoom and the original pixel at the
  middle there and back, clamps into a smaller frame, and leaves a fitted view fitted.
- **Unit, real files** (`EditorSessionTests`): with the Crop tool the canvas image is the
  original and its items every annotation in original coordinates; drawn, moved, and resized
  crops save as one `edits.json` crop; other tools show the crop; saving and reopening (and a
  script that moves the crop and crops by `rect`) keep every annotation exactly as drawn.
- **App end to end** (`scripts/app-e2e.sh`): an `--annotate` script draws, moves, and resizes the
  crop with the Crop tool (edits.json 50,40 230 × 100, the hint and messages), then draws a rect
  on the crop that lands at the crop's origin in file coordinates; the render is 230 × 100.
- **Visual QA:** `editor-crop-drag`, `editor-crop-tool`, `editor-crop-adjust`, `editor-cropped`
  (`--render-ui-previews`), inspected by hand.
- **Not covered automatically:** live mouse and trackpad crop gestures (`HS2-7MFNJP`).

## HS2-9RRP8G: Crop tool resize and move cursors

- **Unit** (`CanvasCursorTests`): arrow with Select, crosshair with drawing tools (and the Crop
  tool without media); with the Crop tool, each edge and corner's resize cursor, an open hand
  inside a crop, and a crosshair elsewhere, always equal to what a press there grabs
  (`cropHandle`); the tolerance follows the zoom; an uncropped original's edges; a tiny crop's
  nearer corner; during a move a closed hand anywhere, during a resize the grabbed handle's
  cursor even inside, while drawing a crosshair; cancel, undo, and tool switches under a still
  pointer.
- **Not covered automatically:** cursors can't be captured offscreen, so the AppKit wiring
  (tracking area, `resetCursorRects`, `NSCursor.frameResize`) needs a live pointer check
  (`HS2-GADPT1`).

## HS2-M03YP2: crop videos (simulated in the editor, applied when submitting)

- **Unit** (`CropToolTests`, `ImageCropTests`): the Crop tool shows a video's whole frame and
  crops it with even sides (an odd side grows right/down, else left/up at the edge); tiny and
  whole-frame video crops are refused; Restore Original removes the crop and the trim as one
  undo step; the random walk includes the video and checks its crops stay even;
  `PixelRect.evened` and `VideoTrim.renderSize`.
- **Unit, real files** (`VideoCropTests`, a 160 × 90 movie in four colored quadrants that change
  after 1 s): the Crop tool canvas is the whole frame and other tools the cut frame (pixel colors
  at a point in each quadrant), player-sized frames are cut the same way, the trim shows the
  second colors, saving leaves the movie byte-identical with the crop in `edits.json` next to the
  trim; `SubmissionPreview` reports 80 × 50, 1 s, one annotation left out ("the crop or trim");
  the thumbnail is the cut frame at the trim start; `SubmissionStaging` exports an 80 × 50, 1 s
  movie whose frames have the expected colors, with the outside annotation dropped and the
  inside one mapped. With AI downscaling the same single export crops, then scales (40 × 24 or 26
  from the 80 × 50 crop, `scaledFrom` the crop's size, "cropped, scaled for AI", colors per
  quadrant). A crop alone keeps the whole length; an odd record renders at the even
  size below; Restore Original in a later session clears both edits.
- **App end to end** (`scripts/app-e2e.sh`): the submit flow crops the narrated clip with the Crop
  tool (101 × 61 dragged, recorded as 102 × 62 next to the 0–800 ms trim, the draft movie
  unchanged); the ticket receives an H.264 102 × 62, 0.8 s clip whose frame at 0.4 s matches
  ffmpeg's crop of the draft movie at (20, 20) (mean difference ≤ 8 per channel), and
  review.json says 102 × 62.
- **Visual QA:** `editor-video-crop-tool` and `editor-video-cropped` (`--render-ui-previews`),
  inspected by hand.
- **Not covered automatically:** playing a cropped video in the window, the Submit Review
  window's cropped movie thumbnail on screen, and rotated or odd-sized imported movies
  (`HS2-5KWZPJ`). The export session calls are deprecated in macOS 15 (`HS2-XA294W`).

## HS2-SZ6T9T: UX Review windows open in front of other apps' windows

- **Build + app e2e** (`scripts/check.sh`): every window controller (editor, Submit Review,
  Draft Reviews, Settings) presents through `DockPresence.present`.
- **Not covered automatically:** window ordering against other apps needs a live window server
  and a person at a Mac (activation and window ordering are blocked headlessly); see the
  follow-up live check.

## HS2-XCJPTX: typing in the middle of a note keeps the insertion point

- **App end to end** (`scripts/app-e2e.sh`): `--render-ui-previews` hosts the editor with
  annotation #1 selected, puts the insertion point after "Field label" in the real note text
  view, and types X, Y, Z one at a time with the run loop turning in between
  (`editor-note-typing.json`). The insertion point must be 12, 13, 14, and the text view and the
  model must both read "Field labelXYZ is clipped…". Before the fix it jumped to the end (43)
  after the first character.

## HS2-J2BE94: the Submit Review window fits the success message

- **App end to end** (`scripts/app-e2e.sh`): `--render-ui-previews` puts a filed review in a
  640 × 2000 window and runs `ReviewSessionWindowController.fitToSubmitted`
  (`session-submitted-fit.json`). The window must end up 520 pt wide, 150–400 pt tall, with its top
  edge kept and no longer resizable.
- **Visual QA:** `session-submitted-fitted.png`, inspected by hand.
- **Not covered automatically:** the live resize animation, and that the next window opens at
  the form's saved size (autosave is turned off before the resize).

## HS2-8QBS4V: zoom lives in a View menu

- **Unit** (`CanvasViewport` tests, unchanged): fit, actual pixels, zoom stops, anchors.
- **App end to end** (`scripts/app-e2e.sh`): `menus.json` has the menu bar order UX Review, File,
  Edit, View, Capture, Window, and the View menu's items, shortcuts, and actions: Actual Size ⌘0,
  Zoom to Fit ⌘9, Zoom In ⌘+ (and a hidden ⌘=), Zoom Out ⌘-. Editor renders show no zoom
  controls in the tool bar.
- **Not covered automatically:** choosing the items in a live editor window (the actions forward
  to the same `EditorModel` zoom functions the old tool bar used).

## HS2-KJCJWX: toasts instead of the editor's status line

- **Unit** (`EditorToastTests`): a save error wins over a message, and empty or routine states
  show nothing. Info fades after 4 s and errors never expire. `ToastPresenter` walks show →
  expire → hidden, a repeated expiry, clear → the same message showing again, a new message after
  an expired one, a stale expiry that doesn't hide an error, and clearing once saving works.
- **Visual QA:** `editor-crop-tool` ("Cropped to 1180 × 560 px…") and `editor-video-trimmed`
  ("Trimmed to 2.5 s.") show the toast at the top of the canvas (`--render-ui-previews`); the
  tool bar has no status text.
- **Not covered automatically:** the live fade timing and animation.

## HS2-WHP4V1: the editor's tools in a native toolbar

- **App end to end** (`scripts/app-e2e.sh`): `--render-ui-previews` builds a titled window with
  the real `EditorToolbar` (`editor-toolbar.json`). It must be unified with the title shown, and
  hold flexible space, tools, space, Restore Original, and Submit Review… in that order. The tool
  tips name the shortcuts. Select is selected and Restore Original hidden on open; after the C
  key's tool change and a crop, Crop is selected and Restore Original shown; choosing Submit
  Review… runs the window's submit.
- **Visual QA:** `editor-window.png` (the window frame with title bar and toolbar), inspected by hand.
- **Not covered automatically:** the Liquid Glass look and the prominent Submit Review… tint in a
  live, active window (offscreen renders draw the prominent button blank); see the follow-up
  live check.

## HS2-AH6HW4: the capture sidebar is resizable

- **Unit** (`MediaStripWidthTests`): widths clamp to 96–320 pt, and a NaN or infinite saved width
  becomes the standard 112. The standard strip keeps 88 × 60 thumbnails, which scale with the
  width. Drags past either end stick there and come back within the same drag (measured from the
  drag's start); a second drag starts where the first ended.
- **Visual QA:** `editor-wide-sidebar` (`--render-ui-previews`, a 240 pt strip with larger
  thumbnails) next to the standard-width editor renders.
- **Not covered automatically:** dragging the live divider, its resize cursor, and the
  double-click reset; see the live-check follow-up.


## HS2-3239JD: no Capture menu in the app menu bar

- **App end to end** (`scripts/app-e2e.sh`): `menus.json`'s `mainMenu` is exactly UX Review,
  File, Edit, View, Window.
- **Unit:** the Capture menu's builder and its test are gone; `AppMenusTests` still covers the
  menu bar menu in every capture phase.

## HS2-VX8T5A: windows no taller than their content needs

Root cause: an `NSHostingView` sets the window's minimum size to its SwiftUI root view's, and
SwiftUI measures the minimum height at the minimum width. With no minimum width, the wrapping
text stacked one word per line at 99 pt wide. The empty Draft Reviews window was forced to
1663 pt and a filed Submit Review window to 2026 pt, and those frames were then saved.

- **Unit** (`WindowFrameFitTests`): a frame that fits is untouched; the saved 640 × 2042 frame
  from the bug shrinks to the screen, or back to the window's opening size when given (never
  below the minimum, never above the screen); frames sticking out of each edge move in; a frame on a
  missing display comes back whole; wider than the screen; never below the minimum size (title bar
  kept reachable); an offset second screen; no visible area; fitting twice equals fitting once.
- **App end to end** (`scripts/app-e2e.sh`): `--render-ui-previews` builds the real window
  controllers (saved frames off), lets SwiftUI lay them out over several run loop turns, and
  checks `drafts-window.json` (empty and listing: 640 × 460, minimum 560 × 320),
  `session-submitted-fit.json` (form 640 × 680, minimum 520 × 480; filed 520 wide, 150–400 tall)
  and `editor-window.json` (1240 wide, minimum 900 × 560). Without the fix the same checks read
  1663 and 2026 pt. `drafts-window-empty.png`, `drafts-window-list.png`, and
  `session-submitted-fitted.png` draw the result.
- **Not covered automatically:** restoring the user's real saved frames on a live screen
  (`WindowSizing.keepOnScreen` calls the unit-tested `WindowFrameFit`).

## HS2-5D947C: the editor toolbar check waits for the toolbar

- **App end to end** (`scripts/app-e2e.sh`, `toolbar: states`): after the crop,
  `EditorPreviews.renderToolbar` waits up to 2 s for Restore Original to show before reading the
  toolbar, instead of a single 50 ms run loop turn that a loaded machine could miss. A real
  regression still fails: the state never arrives and the check reads it as before.

## HS2-8HMGTD: Hot Sheet project first in Submit Review

- **Visual QA:** `session-ready`, `session-narrow`, and `session-issues` (`--render-ui-previews`)
  show Hot Sheet project above Review, Captures, and Ticket; inspected by hand.
- **Not covered automatically:** the section order itself. SwiftUI builds no accessibility tree
  for an offscreen `Form`, so there is nothing to read the order from without a live window.

## HS2-HQV9R8: arrow heads at each end

- **Unit** (`ArrowHeadsTests`): the standard arrow writes no heads, and only non-default heads are
  written; all 36 combinations round-trip; older arrows read as standard; an unknown head is
  rejected; the schema's `arrowHead` enum matches the model; the example's span. The default
  intent across all 36 combinations (move only for a one-way arrow). Editor: new arrows are
  standard; set, set again, undo, undo, redo, and a no-op (one undo step each); not on a rectangle
  or a missing id; chosen intents survive a head change; nudge, vertex drag, duplicate, and crop
  keep the heads. VoiceOver label; the `heads` script op (missing end kept, empty and unknown
  rejected); the ticket's shape line; the line stopping at an open circle.
- **Hot Sheet end to end** (`HotSheetEndToEndTests`): the example's span is filed as `#6 · comment`
  with `Shape: arrow (start flat, end flat)`.
- **App end to end** (`scripts/app-e2e.sh`): `--annotate` sets heads on a real draft with
  undo/redo; `review.json` holds `startHead`/`endHead`, validates against the schema, and the span
  defaults to comment; going back to standard writes no heads and defaults to move; heads on a
  rectangle exit 2; `--render-dir` draws it.
- **Visual QA:** `editor-arrow-heads` (`--render-ui-previews`): one arrow per style and a selected
  span with its Arrow heads menus, inspected by hand (the first render showed the menus pushing the
  inspector wider than 300 pt; fixed).

## HS2-1DDKZ3: editable ticket text in Submit Review

- **Unit** (`TicketPreambleTests`, `MarkdownBlockTests`): both standard templates fill in to the
  text filed before (the intake body still starts with it); one-pass placeholder rendering (a
  value holding `{{…}}` isn't expanded again; unknown, unclosed, and empty placeholders stay as
  typed); each mode's variables; an edited and a cleared preamble replace only the preamble, for
  the body and the note. `ticket-text.json`: missing, edited, standard text stored as standard (the
  file is removed), cleared (kept as an edit), unreadable. Interleaved edits and resets across both
  modes, then a refill. `DraftSubmitter` files a new ticket with the new-ticket text and an existing
  ticket's note with the existing-ticket text, never the other. The Markdown block parser handles
  headings, numbered (`1.` / `12)`) and bulleted items, continued items, joined paragraphs, and
  non-headings.
- **Hot Sheet end to end** (`HotSheetEndToEndTests.filesTheDraftsEditedTicketText`): through the
  real `hotsheet-cli`, an edited intake preamble with `{{title}}`, `{{record}}`, and `{{media}}`, then
  an edited note on an existing ticket whose `{{record}}` is the renamed `review (2).json`.
- **Visual QA** (`--render-ui-previews`, listed in `scripts/app-e2e.sh`): `session-ticket-text-new`,
  `-existing`, `-edited`, `-editing`, and `-narrow`, inspected by hand. The first render drew one
  inline code span in proportional type; code spans now get an explicit monospaced font.
- **Not covered automatically:** clicking the rendered text and typing into the live editor. The
  model calls (`setPreamble`) are thin wrappers over the tested store method.

## HS2-D1T46P: Change lists recent projects first

- **Unit** (`ReviewSessionTests.changeMenuListsRecentProjectsWithTheCurrentOneChecked`): order,
  the current project checked (with a trailing slash), a current project that isn't recent
  listed first, a gone folder left out unless it is the current one, clashing folder names
  shown as paths, empty and root cases. `recentProjectsAreDedupedCappedAndPersisted` now caps at 10.
- **Not covered automatically:** the open menu itself. SwiftUI doesn't render a closed `Menu`'s
  items offscreen; the view only maps `ProjectMenuItem`s to toggles plus Choose Folder….

## HS2-KMB528: the size before AI downscaling in review.json and the ticket

- **Unit** (`ScaledFromTests`, `SubmissionScalingTests`): `scaledFrom` round-trips and is
  omitted when unscaled; the media line ("scaled from 3840×2160", also before a movie's
  duration) and the hint show only when something was scaled; a non-positive `scaledFrom` is
  `invalidMediaSize`. Staging records the size before scaling (after the crop) and none without a
  scale. `DraftSubmitter` attaches a `review.json` carrying it and files a ticket that names it.
- **App end to end** (`scripts/app-e2e.sh`, every `downscale_case`): the attached `review.json`
  has `scaledFrom` 3840x2400 when scaled and none at full size, it validates against the schema
  (ajv), and the ticket file's media line reads `(image, W×H, scaled from 3840×2400)`.

## HS2-ZEF6XD: Open in Hot Sheet after filing

- **Unit** (`HotSheetWebClientTests`):
  - `HOTSHEET_HOME` and the default home;
  - loopback records read (IPv4, IPv6, localhost); missing, broken, pid-less, zero-pid, remote, LAN, `file:`, and empty-URL records ignored;
  - discovery needs a live pid and an answering URL, and a removed record means no client;
  - `processIsAlive` for this process and a free pid;
  - deep-link encoding of spaces, `+`, `&`, `=`, and a client URL with a path;
  - `answers` against a real local TCP listener (a 404 counts), and not after it closes.
- **App end to end** (`scripts/app-e2e.sh`): `--submit` with a fake web host (a node HTTP server that writes `client.json` with its own pid) reports `hotSheetURL` as `<url>/?store=<store>&ticket=<slug>`; with an empty `HOTSHEET_HOME` it reports none.
- **Visual QA:** `session-submitted-hotsheet` (`--render-ui-previews`), inspected by hand; `session-submitted` still has no button.
- **Not covered automatically:** clicking the button and the browser opening the link (`NSWorkspace.open`).

## HS2-ZMDH5D: AI downscaling of rotated movies, and the Settings / Submit Review wiring

- **Real files** (`EncodingTests.RotatedMovieScalingTests`): H.264 movies written with
  `AVAssetWriter` and a track transform.
  - An iPhone-style portrait clip (quarter turn, stored 160×90) imports at 90×160. The Submit
    Review text, the staged movie (`SubmissionStaging`), and the bundle all give the scaled
    portrait size (longest edge 80, even sides). The filed track has an identity transform, its
    quadrant colors match the displayed source, and `scaledFrom` is 90×160.
  - A half turn whose displayed frame lies at negative coordinates, through `VideoTrim.export`,
    comes out upright with the displayed colors. A crop of the displayed top half keeps what is
    shown, not the stored pixels.
  - `renderTransform` maps both rotations' displayed frames onto the output frame's origin and size.
  - Mutation check: making `renderTransform` ignore the preferred transform fails all three tests.
- **App end to end** (`scripts/app-e2e.sh`, `session-downscale-wiring.json` from
  `--render-ui-previews`): the Settings view's own toggle binding saves `downscaleForAI` (in a
  throwaway store). `SettingsModel` posts `captureSettingsChanged`, and an open
  `ReviewSessionModel` re-reads the setting (`refreshScale`) and shows the filed sizes:
  "1389×868 scaled for Claude" → "1600×1000" → scaled again, with one AI size detection reused.
  The three states are also rendered (`session-downscale-opened`, `-off`, `-on-again`) for visual QA.
- **Not covered automatically:** clicking the toggle in a live Settings window (the probe drives the
  same binding).

## HS2-BKWZ5N: reviews as .uxreview documents

- **Unit** (`ReviewDocumentTests`, `RecentReviewsTests`, `ReviewDocumentCommandTests`):
  - new reviews are untitled `.uxreview` packages and the pointer names them;
  - Save moves a review anywhere (adding the extension); it stays current via an absolute pointer and the next capture goes into it; saving in place is a no-op; a non-current review's save leaves the current one alone;
  - an existing destination is refused, or with `replacing` moved to the Trash;
  - a pending submission moves with Save but never into copies (`submission.json`, `.submission/`);
  - Save As and Duplicate give fresh ids, the original is untouched, Duplicate is untitled and titled "… copy";
  - Open reads a package anywhere; makeCurrent refuses a non-review without changing the pointer;
  - filing removes an untitled review and trashes a saved one; discarding a saved one trashes it;
  - only real packages outside the drafts folder are accepted (plain folders, empty packages, and links are refused); malformed pointers are ignored;
  - a whole life cycle across the operations;
  - the recent list notes, caps, dedupes, moves, removes, clears, persists, and titles entries (repeats told apart, missing ones skipped);
  - command parsing and name resolution with or without the extension.
- **Existing tests** (`ReviewDraftStoreTests`, `DraftListingTests`) now expect `.uxreview` folder names.
- **App end to end** (`scripts/app-e2e.sh`, "reviews as documents"):
  - the built app's Info.plist exports the UTI and declares an editable package document type;
  - a capture makes an untitled package; `--save-review` moves it and the pointer and the next capture follow;
  - `--copy` writes a separate copy with its own id (validated with ajv), and an existing name exits 4 without `--replace`;
  - `--duplicate-review` makes an untitled "… copy"; `--open-review` makes a review current, and a non-review exits 2 without changing it;
  - discarding a saved review trashes the package;
  - the File menu dump matches the new File menu.
- **Not covered automatically:** the save and open panels, the Open Recent submenu filled live, Finder opening a `.uxreview`, and the editor reopening after Save (live check `HS2-WXZVDJ`).

## HS2-0D87NR: Duplicate and Save As… (⌥)

- **Unit** (`ReviewDocumentTests`, shared with HS2-BKWZ5N): Save As writes a separate copy with
  its own id and leaves the original and the current review alone; an existing destination is
  refused unless replacing; Duplicate makes an untitled "… copy"; copies never carry a pending
  submission.
- **App end to end:** `--save-review --copy` and `--duplicate-review` (see HS2-BKWZ5N); the File
  menu dump has Duplicate ⇧⌘S followed by Save As… ⌥⇧⌘S as its alternate item.
- **Not covered automatically:** the ⌥ swap in the open menu, the save panel, and the original's
  windows closing as the copy opens (live check `HS2-WXZVDJ`).

## HS2-QXJZJ9: every media strip thumbnail takes its clicks

- **App end to end** (`scripts/app-e2e.sh`): `--render-ui-previews` shows a draft of a
  landscape, a tall portrait (600 × 1600), and two more landscape captures in a key window far
  off screen, and sends real mouse down/up events every 3 pt down two columns of the strip (the
  middle, and beside the filename), parking on the fourth capture before each click
  (`editor-strip-clicks.json`). Each column must read: nothing, capture 1, nothing, capture 2,
  nothing, capture 3, nothing, with each capture's band at least 26 clicks (78 pt) tall. Before
  the fix, the portrait thumbnail's clipped overflow covered capture 1 completely (no click on it
  did anything) and the filename row of capture 3 had a dead gap.
- **Visual QA:** `editor-strip-portrait` (the portrait capture shown), inspected by hand.
- **Unit:** none; the fix is two SwiftUI hit-test shapes with no logic of their own.
- **Not covered automatically:** a person clicking in a live window; see the follow-up live check.

## HS2-4R84WH: the inspector is a navigation stack

- **Unit** (`InspectorNavigationTests`): the path is `[]` or `[selection]`. Stack changes map to
  selection changes: unchanged (nothing to do), Back (deselect), push, push over a page.
  A real editor walks row click → canvas pick of another (replaces) → Back → Back again → canvas
  pick → Esc → Tab → delete (pops) → undo (pushes back) → another capture (pops). Also empty then
  refilled, and a stale row id selecting nothing.
- **App end to end** (`scripts/app-e2e.sh`): `--render-ui-previews` drives the real editor in an
  off-screen key window (`editor-inspector-navigation.json`). A real click on the first list row
  selects annotation #1 and pushes its page; a real click on Back clears the selection; ⌘[ (a key
  equivalent through the window) is handled and clears it; a note-focus request made just before a
  push leaves the note text view focused.
- **Visual QA:** `editor-inspector-list`, `editor-inspector-pushed`, `editor-annotated`,
  `editor-narrow`, `editor-video-narrow`, and `editor-window`, inspected by hand.
- **Not covered automatically:** the push/pop animation and VoiceOver reading the rows in a live
  window; see the live-check follow-up.

## HS2-KVDDFH: capture notes

- **Unit** (`MediaNoteTests`):
  - the note round-trips and is omitted when absent, and an older bundle without it reads as none;
  - the spec example carries one and validates;
  - typing coalesces per capture, undo/redo work, and an empty note is stored as none (a repeat changes nothing), interleaved with an annotation's note;
  - the `media-note` script op parses, and a missing `text` is rejected;
  - the media list puts the note (multi-line, with blank lines) inside the capture's list item, in both the intake ticket and the existing-ticket note;
  - a capture left out by `ReviewSelection` takes its note with it;
  - through real files (`EditorSession`): saved, read back by a new editor, kept when a capture is added, removed from disk once cleared, and an unknown capture fails the script step.
- **App end to end** (`scripts/app-e2e.sh`, the Claude standard-tier submission):
  - `--annotate` sets a two-line note on capture 1, and sets then clears one on capture 2;
  - the draft's `review.json` has the first and omits the second;
  - the filed `review.json` (after AI downscaling; ajv-validated against the schema) keeps it;
  - the ticket file has `  Capture note: Feels cramped.` and `  Give the form room.` under the media line.
- **Spec:** `spec/review-bundle.schema.json` lists `note` (a non-empty string); the example uses it (ajv in `scripts/check.sh`).
- **Visual QA:** `editor-capture-note` and `editor-empty` (the empty field with its placeholder), inspected by hand.
- **Not covered automatically:** typing into the live field (it uses the same model call the script op uses).

## HS2-WNZVXR: open the editor after each capture

- **Unit** (`SettingsTests`): on by default; stored JSON includes it; older settings without
  it, and `null`, read as on; `false` reads back; `--set-open-editor on|off` (any case) applies,
  a bad value is rejected, other flags leave it alone.
- **App end to end:** `--settings` reports it on by default, `--set-open-editor off` persists,
  a bad value exits 2.
- **Not covered automatically:** the editor opening after a live capture (the coordinator calls
  the tested `EditorWindowController.show(directory:store:mediaId:)` when the setting is on;
  headless captures never open windows). Live check: `HS2-MCJWZ6`.

## HS2-FDG3D9: note labels name the content

- **Visual QA:** `editor-window`, `editor-empty`, `editor-capture-note`, and
  `editor-video-timeline` (`--render-ui-previews`) show **Note** and **Capture note** with no
  format hint, inspected by hand.
- **Not covered automatically:** the Markdown tooltip (`.help`). SwiftUI builds its accessibility
  tree only while an assistive client is attached, so the offscreen renders can't read it; it is
  part of the VoiceOver walkthrough `HS2-MVGVJ4`.

## HS2-3B3RB6: the editor window's title

- **App end to end** (`scripts/app-e2e.sh`): `editor-toolbar.json` from `--render-ui-previews`
  (the window built by the same `EditorWindowController.title(_:for:)` the editor uses) has the
  title `Acme Mail review` and the subtitle `Not saved` (the preview review is untitled), read
  after SwiftUI's layout. This pins a regression: the inspector's `NavigationStack` bridged its
  empty navigation title into the window and cleared the subtitle, so `EditorHostingView` now
  sets `sceneBridgingOptions = []`.
- **Visual QA:** `editor-window`, inspected by hand.
- **Not covered automatically:** the Window menu and Mission Control names (both read
  `NSWindow.title`), and the proxy icon of a saved review (set by the same function).

## HS2-56FCW3: the Submit Review… button in renders

- **App end to end** (`scripts/app-e2e.sh`): `editor-toolbar.json` reports the item's style as
  `prominent`, and the `NSToolbarButton` AppKit made for it as titled "Submit Review…", enabled,
  visible, and inside an `NSGlassEffectView`.
- **Known render limit:** Liquid Glass (toolbar platters, the prominent accent fill) is drawn by
  the window server, so `cacheDisplay` can't capture it. In `editor-window.png` the button is a white
  capsule with a white label. This comes from the offscreen render, not from the app.
- **Not covered automatically:** the composited button in light/dark and active/inactive windows
  (screen capture needs Screen Recording permission). Live check: `HS2-3AWMBZ`.

## HS2-YE2X53: the tool picker as one capsule

- **App end to end** (`scripts/app-e2e.sh`): `editor-toolbar.json` reports that the tools are one
  item view (a row of buttons, not a segmented group with dividers), that Insertion's symbol is
  `text.insert`, and that exactly one tool shows selected after opening (Select) and after C (Crop).
  It also checks that a real button click chooses Rectangle and a second click keeps it chosen
  (the model's tool too), and that the overflow **Tools** menu lists all seven tools. The
  tooltips `Select (V)` … `Crop (C)` are asserted as before.
- **Visual QA:** `editor-window` (`--render-ui-previews`), inspected by hand.
- **Not covered automatically:** hover borders and the overflow menu in a narrow live window.
  VoiceOver reading each button's label is part of `HS2-MVGVJ4`.

## HS2-JMCM6S: the canvas follows the appearance

- **App end to end** (`scripts/app-e2e.sh`): `editor-canvas-colors.json` samples the rendered
  surround below the capture. In `editor-annotated` (light) it is a light gray (200–245, now 235);
  in the new `editor-annotated-dark` it is near-black (≤ 80); both are neutral. Both PNGs and
  `editor-empty-dark` must exist.
- **Visual QA:** `editor-annotated`, `editor-annotated-dark`, `editor-empty`, `editor-empty-dark`,
  inspected by hand: the white screenshot keeps a visible edge (shadow and hairline) on the light
  surround, and the empty-canvas text uses the secondary label color in both appearances.
- Editor previews now render in light mode by default (`snapshot(appearance:)`), so they no
  longer depend on the Mac's own appearance.
- **Not covered automatically:** switching appearance while the editor is open (the canvas
  redraws in `viewDidChangeEffectiveAppearance`).

## HS2-0CZ5RR: intent chips don't rely on color

- **Unit** (`IntentContrastTests`): the WCAG luminance and contrast math. On light chips exactly
  change, insert, move, and question need the ring (question is the faintest, < 1.5:1). On dark
  chips no dot needs it. In both appearances every dot, or its ring, meets 3:1.
- **Visual QA:** `editor-window`, `editor-annotated`, `editor-annotated-dark`, and
  `editor-intent-single` (`--render-ui-previews`), inspected by hand: on chips show a check circle
  and a thicker border, and off dots show their ring where needed.
- **Not covered automatically:** VoiceOver announcing "selected" (`.isSelected` trait); part of
  `HS2-MVGVJ4`.

## HS2-H00SFD: the time rows' playhead controls

- **Visual QA:** `editor-video-timeline` and `editor-video-narrow` (`--render-ui-previews`),
  inspected by hand: each of From and To has its field, then one **Go To | Use Playhead** group,
  aligned across both rows, fitting the inspector at 1240 and 900 points wide.
- The buttons call the same model operations as before (`movePlayhead(to:)`,
  `setRangeEnd(_:toMs:for:)`), which `VideoTimeTests` and `TimelineDragTests` cover.
- **Not covered automatically:** clicking the buttons in the live inspector, and VoiceOver reading
  their labels (part of `HS2-MVGVJ4`).

## HS2-WTPT8X: the strip's ✕ only on hover

- **Visual QA:** `editor-empty` and the other editor renders show the shown thumbnail with no ✕
  (at rest); the new `editor-strip-hover` (`--render-ui-previews`, hover drawn on) shows it.
  Both inspected by hand; `scripts/app-e2e.sh` requires the new PNG.
- **App end to end:** the strip-click sweep (`HS2-QXJZJ9`) still lands every click on its capture
  now that no ✕ covers the shown thumbnail's corner.
- **Not covered automatically:** real pointer hover and Full Keyboard Access focus revealing the
  ✕, and VoiceOver's Remove action (`HS2-MVGVJ4`). Removal itself is covered by the
  `HS2-SSM1E7` tests.

## HS2-XSXV5E: the timeline bar in a narrow window

- **App end to end** (`scripts/app-e2e.sh`): `editor-video-layout.json` records the canvas height
  in each video render. The 900 × 560 `editor-video-narrow` canvas is exactly 240 points shorter
  than the 1240 × 800 one, so the timeline bar kept its height. Before the fix, "/ 0:03.00" wrapped
  a character per line and grew the bar.
- **Visual QA:** `editor-video-narrow` (Trim Start / Trim End as icons, the duration on one line)
  and `editor-video-timeline` (titles shown), inspected by hand.

## HS2-RZVDEQ: the inspector always fits the window

- **Unit** (`MediaStripWidthTests.theStripNarrowsToFitTheWindow`): `MediaStripWidth.fitted`
  narrows a saved width to the space left (320 → 178 at the 900-point minimum). It keeps a width
  that fits, never goes below the minimum, still maps a bad width to standard, and passes the
  clamped width through before the window's width is known. Narrow → wide → narrow → wide gives
  the same width each time for the same space.
- **App end to end** (`scripts/app-e2e.sh`): `editor-video-layout.json` records each video
  render's canvas frame. Canvas right edge + 1 + 300 equals the window width for the wide, the
  narrow, and the new `editor-video-narrow-wide-strip` (320-point saved strip at 900 × 560), whose
  canvas starts at 179 (the strip gave way to 178). Before the fix the columns overflowed and
  clipped the inspector's right margin.
- The video renders now pass the strip width (standard) instead of reading the Mac's saved one,
  so they're the same on every machine.
- **Visual QA:** `editor-video-narrow`, `editor-video-narrow-wide-strip`: a 12-point margin on
  both sides of the inspector.
- **Not covered automatically:** dragging the divider in a narrow live window (the drag starts
  from the shown width).

## HS2-CWTNY2: capture links (`uxreview://capture?…`)

- **Unit** (`CaptureLinkTests`):
  - a bare link's defaults (region screenshot into the current review), and both spellings of the action;
  - every parameter and its synonyms;
  - presets choose a new review unless `review=current`;
  - every rejection: unknown action or parameter, a repeated parameter, bad kind, target, delay, narrate, project, ticket, title, context, or review, and narrate without video;
  - preparing: a new review with its title, notes, and `launch.json`, leaving the review in progress alone, then the next capture landing in it;
  - a bare link changing nothing;
  - links into the current review in turn (notes added, title, project, and ticket replaced, the rest kept), and two `new` links making two reviews;
  - `launch.json` round trip, removal when empty, and a corrupt file reading as none;
  - project precedence: `--project`, then the link, then the setting.
- **App end to end** (`scripts/app-e2e.sh`), with `--open-url`:
  - a typo and narrate-on-a-screenshot exit 2 with their codes;
  - a bare link prepares nothing;
  - a full link starts a new review (title, notes) with `launch.json` and leaves the earlier review untouched;
  - a synthetic `--capture` goes into it;
  - `--submit` with no `--project` or `--to-ticket` adds it to the link's ticket in the link's project, and the ticket shows the title and context.
- **Not covered automatically:** clicking a real `uxreview://` link in a browser. That covers Launch Services routing, a cold launch, and the app stepping back so the page is the capture's app. The `AppDelegate` routing and `CaptureCoordinator.openLink` are thin. Live check: `HS2-P50AJK`.

## HS2-CR8M4X: the new ticket's title

- **Unit** (`TicketTitleTests`):
  - typed titles become one trimmed line (`\r\n` included); blank or standard is none;
  - composing uses the typed title, the body unchanged;
  - storage beside an edited preamble, each clearing on its own; the file is removed when standard; an older file reads as standard;
  - filing a new ticket under the typed title, else "UX review: <review title>";
  - `--ticket-title` parsing: not with `--to-ticket`, not blank, needs a value.
- **App end to end** (`scripts/app-e2e.sh`): `--ticket-title` with `--to-ticket` exits 2 and keeps
  the draft. `--submit --ticket-title "  Checkout: clipped labels "` files a real Hot Sheet ticket
  whose title is exactly `Checkout: clipped labels`.
- **Visual QA:** `session-ticket-text-new` (the prompt shows the standard title) and
  `session-ticket-text-edited` (a typed title) from `--render-ui-previews`, inspected by hand.
- **Not covered automatically:** typing in the live field. It keeps its own text, so spaces
  survive, and saves each change through the tested `setTicketTitle`.

## HS2-G3BA3P: Open in Hot Sheet names the project

- **Unit** (`HotSheetWebClientTests.deepLinkNamesTheProjectWhenItIsKnown`): the link carries the
  project folder (standardized: trailing slash, `..`). A blank project falls back to the store
  path. Spaces and reserved characters are encoded. The store-only cases keep passing.
- **App end to end** (`scripts/app-e2e.sh`, HS2-ZEF6XD block): with a running fake web client,
  `--submit --project <dir>` reports `hotSheetURL` as `<client>/?store=<dir>&ticket=<slug>`.
- **Not covered automatically:** Hot Sheet 2 opening that link (its `HS2-RVSPQ9` deep link
  accepts a project path), covered by the live check `HS2-K4KHR3`.

## HS2-RA1Y5Z: the tool group's padding

- **App end to end:** `editor-toolbar.json` reports every tool button at 32 × 28 and the row's
  insets at 6 points on each side.
- **Visual QA:** `editor-window` (`--render-ui-previews`): the selected tool's highlight sits
  inside the capsule, inspected by hand. The live glass rendering is part of `HS2-3AWMBZ`'s check.
