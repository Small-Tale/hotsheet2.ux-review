# Live macOS UI testing

`UXReviewUITests` exercises the shipped app through XCTest UI automation. Its XcodeGen
target and scheme live in `macos/project.yml`; regenerate the project with
`scripts/macos-project.sh`. The `UITesting` build configuration uses identical app sources
with bundle ID `com.smalltale.uxreview.uitesting`, so an installed UX Review copy is not
launched, activated or terminated by the tests. The normal Debug/Release app identity stays
`com.smalltale.uxreview`. Run live UI tests serially with the headless app suite: XCUITest launch/termination can
interrupt another process with the same application identity. This suite complements the unit tests and headless
`scripts/app-e2e.sh` checks described in [TEST-COVERAGE.md](TEST-COVERAGE.md).

## Running and reviewing evidence

Run from the repository root on a logged-in, unlocked macOS desktop with Xcode selected.
The wrapper holds a temporary `caffeinate` assertion to prevent display/system idle sleep
until it exits; it cannot unlock a locked Mac. Locking the desktop during a run prevents
physical UI events even though accessibility queries may still find the app.

```sh
scripts/ui-e2e.sh
scripts/ui-e2e.sh -only-testing:UXReviewUITests/AppUITests/testStatusMenuSettingsPersistAcrossRelaunch
RUN_UI_TESTS=1 scripts/check.sh
```

The wrapper accepts additional `xcodebuild` test-selection arguments. It saves each run's
result bundle under `${TMPDIR:-/tmp}/uxreview-ui-<uid>/runs/<timestamp>-<pid>/Results.xcresult` and exports its
attachments to the same run directory’s `attachments/` folder. Open the result bundle in Xcode to inspect
test steps, failures, skips, and screenshots; retain the exported PNGs when handing off a
visual review. A green summary with skipped capture tests does not establish real capture
coverage.

On failure, the wrapper preserves the original `xcodebuild` exit status even if result
export also fails. It prints build errors and available test-failure details; missing,
empty, malformed or unexpected summary data falls back to a bounded log tail when no
structured diagnostic is available. Result-export failure still fails an otherwise
successful run. Run the wrapper's isolated shell regressions without launching apps with
`python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -q`; they also run in
`scripts/check.sh`.

The wrapper prints the exact artifact directory. Build products also live under that
temporary root, outside protected checkout locations such as Documents. Preserve the
result bundle or attach inspected screenshots before the operating system clears temporary
files. Both app and runner use `Signing.xcconfig`; configure its existing local development
identity to retain privacy approvals across rebuilds. Ad hoc signing remains the fallback
when no local identity is configured, and may require repeated approval.

Screenshots are XCTest attachments with `.keepAlways`, so successful tests retain their
evidence too. Apple documents both [capturing the current screen or element](https://developer.apple.com/documentation/xcuiautomation/xcuiscreenshot)
and [adding persistent attachments to test results](https://developer.apple.com/documentation/xctest/adding-attachments-to-tests-activities-and-issues).

Inspect the actual images before treating them as correctness evidence: review readability,
clipping, alignment, spacing, contrast, selected states, and window layout. Check the editor
at its normal and minimum supported sizes and inspect Settings and Submit Review. Assertions
about accessibility labels or geometry supplement this review. Attach inspected captures to
the ticket; when a ticket includes a problem image, reproduce that component, state, and
viewport as closely as practical for its after image.

## What the automated suite exercises

Tests launch the normal app and click its real menu bar extra. They open Settings, change
controls, enter the editor through the shipped menu, invoke Add Media with its shipped ⌘⇧O shortcut, import through the real open
panel, annotate with Undo/Redo shortcuts, and open Submit Review from its toolbar button. Submission invokes the installed real
`hotsheet-cli` against an isolated store and verifies the resulting ticket and attached
review files. Readiness checks wait for observable UI state rather than assuming a fixed
launch or submission delay.

Status-menu helpers require a hittable entry with the same nonempty frame across three
readiness polls within five seconds. They click the ready entry's center, avoiding XCTest's
implicit native menu traversal/reopening; callers assert the destination window and controls. They do not retry
the action or automatically reopen a failed menu. A regression cycles through opening,
snapshotting, selecting Settings, and closing Settings three times; the separate
Settings flow checks persistence across app relaunch.

The suite uses live AppKit/SwiftUI windows and controls. It does not substitute offscreen
previews, synthetic capture results, mocked CLI responses, or a test-only route that opens
the desired window at launch. Headless commands may prepare fixtures or inspect persisted
results; they do not stand in for the UI interaction being tested.

Each run uses temporary resources:

| Resource | Isolation |
| --- | --- |
| Settings | `UXREVIEW_DEFAULTS_SUITE` names an absolute temporary `defaults` path, keeping its plist with the run |
| Drafts and discarded reviews | `UXREVIEW_DRAFTS_DIR` and `UXREVIEW_TRASH_DIR` point inside the temporary root |
| Destination project | `--project` selects a temporary project; `HOTSHEET_STORE` forces its real adjacent `.hs2` store |
| Hot Sheet process state | `HOTSHEET_HOME` points inside the temporary root; `HOTSHEET_CLI` resolves the real installed executable |

Fixture setup creates a PNG test card; the test imports it through the real open panel. A fresh real store is initialized with `hotsheet-cli -C
<temporary-project>.hs2 init`. Most flows disable the isolated settings' global shortcuts
to avoid competing with another app instance. The Settings/menu test registers the default
capture/video pair to verify its presentation and registration. Isolated-defaults sessions also disable native
window-frame autosave, which otherwise always uses the app’s standard defaults. Never submit to the working project's store
or use the developer's normal defaults, draft directory, or Trash for test cleanup.

## Permissions and real capture

XCTest needs an interactive desktop and permission to control the app. On development
machines or CI hosts, approve the relevant Xcode/test runner automation or Accessibility
request through macOS when required. If startup reports “Timed out while enabling automation
mode”, run the scheme from Xcode and answer the macOS authentication prompt yourself; the
wrapper does not enable unattended automation or bypass authentication. A headless SSH session or locked desktop is not a
substitute for this environment. Preserve a consistent app signing identity when testing
capture; see [architecture: code signing and permissions](01-architecture.md).

Import, Settings, annotation, and submission do not require Screen Recording or Microphone
permission. Real screen capture is opt-in:

```sh
UXREVIEW_UI_REAL_CAPTURE=1 scripts/ui-e2e.sh
```

The real-capture path first probes permission with the built app's headless capture command,
which does not prompt. Without opt-in, the suite records a skip. With `UXREVIEW_UI_REAL_CAPTURE=1`, real capture
is required and missing permission or an unavailable display fails the test. Review the test summary to distinguish
these outcomes. Grant Screen Recording to the `UITesting` app build through System Settings
before the required run, then relaunch the app as macOS requires. Narration also needs
Microphone permission and is covered by the manual checks below.

Neither the wrapper nor tests automatically grant or reset TCC permissions, alter the TCC
database, or trigger a microphone prompt. Deliberately testing permission denial is a manual
operation in a disposable account or an explicitly prepared environment.

## Manual capture matrix

These regression checks complement automated UI coverage. The cited tickets record earlier
human verification; use this matrix again for capture-related changes. Record the macOS version,
app build/signing identity, display arrangement and scale, granted permissions, and actual
results. Use harmless test content and preserve the captured media and screenshots.

| Scenario | Procedure and expected result | Existing tracking |
| --- | --- | --- |
| Region selection across displays | Arrange displays with different origins, including one above or left of the main display. Drag regions near every display edge; repeat with Esc. The overlay follows the intended display, coordinates match the selected region, and cancellation creates no capture. | `HS2-JG04GX` |
| Window selection | Select windows on each display, move the pointer between windows, and cancel with Esc. The chosen window and its context match; excluded UX Review capture chrome does not become the target. | `HS2-JG04GX` |
| Pixel dimensions at 1x and 2x | Capture known screen regions on each scale and inspect the resulting PNG dimensions and context. Compare point dimensions with display scale; inspect real pixels for clipping, offset, and unintended scaling. | `HS2-JG04GX` |
| Focus and cancellation | Start capture from another app using both menu and configured shortcut. Complete and cancel selection/countdown. Confirm focus returns appropriately and the editor-open setting is honored. | `HS2-3SE1KX`, `HS2-HA9TW3` |
| Screen Recording denial | In a prepared denied state, attempt capture. Confirm the explanation, no draft media written, and Open System Settings reaches the correct privacy pane. Grant permission, relaunch, and retry. Do not reset other users' permissions. | `HS2-3SE1KX`, `HS2-JG04GX` |
| Real video | Record screen, window, and region; stop from the status item and shortcut. Inspect duration, dimensions, region dimming, pointer/click preferences, stop feedback, and the saved editor result on mixed-scale displays. | `HS2-JG04GX`, `HS2-HA9TW3` |
| Narration | With permissions prepared, record speech and check intelligibility and audio/video synchronization. Repeat plain video with narration off. Manually exercise denied permission, Record Without Narration, cancellation, the Microphone Settings link, and unplugging a microphone mid-recording. | `HS2-2T9RMA` |

See [capture requirements](04-capture.md), [start and Settings](05-start-and-settings.md),
[editor requirements](06-annotation-editor.md), and [submission requirements](07-review-session.md)
for the expected behavior. This matrix describes verification work; it does not claim that
the hardware and permission combinations have already passed.
