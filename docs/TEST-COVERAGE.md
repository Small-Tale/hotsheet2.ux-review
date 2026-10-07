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
  - skipping our own PID, decorations, non-zero layers, and invisible windows
  - front window per app
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
