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
Announce immediately before desktop automation begins: it clicks menus, types and resizes
windows, so the person using the Mac needs to know when physical input starts.
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

## Isolated macOS guest runner

`scripts/vm-ui-e2e.sh` runs the same suite inside a dedicated Parallels Desktop macOS
guest, so XCUITest drives the guest's desktop instead of the developer's (HS2-GR8A2A).
It is the default way to run live UI tests on a development Mac; running
`scripts/ui-e2e.sh` directly on the host remains an explicit opt-in that takes over the
host desktop.

```sh
export UXREVIEW_UI_VM="macOS 27"         # name from `prlctl list -a`
scripts/vm-ui-e2e.sh
scripts/vm-ui-e2e.sh -only-testing:UXReviewUITests/AppUITests/testStatusMenuSettingsPersistAcrossRelaunch
```

Each run:

1. Checks that the guest is running with Parallels Tools, that a non-root user is logged in
   at the guest console, that the guest desktop is unlocked, that Xcode is selected, and that
   the guest's visible screen is at least `UXREVIEW_UI_VM_MIN_SIZE` points (default
   `1200x700`, the largest editor size the suite resizes to).
   It exits with status 3 and a specific message otherwise, before copying anything.
2. Stages the tracked and unignored working tree (so never `Signing.local.xcconfig` or local
   Hot Sheet data), the host's `hotsheet-cli`, and the host's `xcodegen` installation, then
   serves them from `scripts/vm_transfer.py`. This one-shot HTTP helper binds only to the
   Parallels host-only address (`UXREVIEW_UI_VM_HOST_IP`, default `10.211.55.2`), serves only
   the staged files, accepts uploads only into the run directory, and stops after each
   transfer. The guest fetches with `curl` into `~/uxreview-vm/` for its console user.
3. Starts `scripts/ui-e2e.sh` detached in the guest user's Aqua session
   (`launchctl asuser`) and polls for completion (`UXREVIEW_UI_VM_TIMEOUT`, default 5400 s).
   Long `prlctl exec` sessions can drop with `PRL_ERR_IO_STOPPED`, so no guest command is
   held open for the duration of the run.
4. Uploads the guest run directory and unpacks it on the host under
   `${UXREVIEW_UI_VM_ARTIFACTS:-$TMPDIR/uxreview-vm-ui}/<timestamp>-<pid>/artifacts/`
   (`Results.xcresult`, `attachments/`, `summary.json`, `xcodebuild.log`), with the guest's
   console output in `guest-output.txt`. The wrapper prints that directory and exits with
   the guest suite's status; a missing artifact upload fails an otherwise green run.

Pointer drags in the guest end a few points short, and a drag of about 5 pt or less is
ignored. The suite's window `resize` helper therefore drags the corner slowly and holds at
the end, then corrects each side from its edge midpoint by growing past the target and
shrinking back, so every drag stays above that threshold, and accepts a size within 4 pt
(`macos/UITests/AppUITests.swift`). Checks that depend on the exact width, such as the
editor's fitted media strip, use `resizeToMinimumWidth`: it drags past the editor's 900 pt
minimum so the window clamps to exactly that width.

Accessibility trust for the UI-test runner is not yet provisioned in the guest, so the
direct-AX sidebar test fails there with `process trusted=false` until `HS2-07PFQX` lands.

The guest builds with ad hoc signing because the developer's local signing identity is not
copied. `UXREVIEW_UI_REAL_CAPTURE` is forwarded unchanged.

### Guest setup

1. Create a macOS guest in Parallels Desktop with the same major macOS version that the
   host's Xcode supports, install Parallels Tools, and log in at its console.
2. Copy the host's `Xcode.app` into the guest's `/Applications` (or install it there from
   the App Store). Host shared folders attach to a macOS guest only after a guest reboot,
   which a FileVault guest cannot finish unattended. Instead, `tar` Xcode on the host,
   `split -b 500m` it, record `shasum -a 256` of the parts, serve them with
   `scripts/vm_transfer.py`, and download each part in the guest until its checksum
   matches before extracting. The Parallels bridge can drop a long stream ("Host is down"),
   so a single 10 GB `curl … | tar -x` is not reliable.
3. Run `UXREVIEW_UI_VM=… scripts/vm-ui-provision.sh`. It changes only the guest: selects
   Xcode, accepts its license, runs first-launch setup, enables developer mode, adds the
   console user to `_developer`, enables unattended UI automation
   (`automationmodetool enable-automationmode-without-authentication`), and disables guest
   sleep and screen saver. Unattended automation is acceptable here because the guest is
   a dedicated test machine; never apply it to the developer host.
4. Dismiss one-time guest banners (for example Xcode's "Multiple Extensions Added") before the
   first run; a banner over the top-right of a window blocks clicks there.

### Recovery

- **"No user is logged in" / "desktop is locked"**: open the guest window in Parallels and
  log in or unlock. With FileVault on, every guest boot needs that manual login, so prefer
  suspending the guest over restarting it.
- **"The guest's visible screen is …"**: Parallels sizes a macOS guest's display from its
  window. Enlarge the guest window (or use a larger scaled resolution in the VM's display
  settings) until the visible area, excluding menu bar and Dock, meets the minimum.
- **"Could not run commands"**: the guest's exec service did not answer. Right after a guest
  boot, or now and then mid-session, `prlctl exec` fails with `PRL_ERR_IO_STOPPED` for up to
  about 30 s; the wrapper retries that connect failure with a growing backoff
  (`UXREVIEW_UI_VM_RETRY_DELAY`, default 3 s per attempt). Repeatable guest commands
  (preflight, sync, status polling, output read-back and artifact upload) also retry
  `PrlJob_GetResult`/`PrlJob_GetRetCode` errors, which can arrive after the command ran. The
  launch is not repeated blindly: it writes `~/uxreview-vm/run.started` and is retried only
  while that marker is missing. If failures persist, restart Tools from the guest's Parallels
  menu or reinstall it.
- **"Guest … is not running (state: invalid)"**: renaming or re-registering the VM in
  Parallels can leave a stale entry under the old name. Use the running name from
  `prlctl list -a`.
- **"Timed out waiting for the guest run"**: the run may still be in progress. Inspect
  `~/uxreview-vm/run-output.txt` in the guest, or quit `xcodebuild` there, before rerunning.
- **Transfer helper failed to start**: check that `UXREVIEW_UI_VM_HOST_IP` matches the
  host's Parallels bridge address (`ifconfig bridge100`) and that the host firewall allows
  incoming connections for `python3`.
- **Automation-mode prompt or timeout in the guest**: rerun `scripts/vm-ui-provision.sh`.

### Real capture lane

Screen Recording and Microphone approvals are per-machine TCC grants that need a person to
approve them in the guest's System Settings. Real capture therefore stays a separately gated
lane in the guest as well: grant Screen Recording to the `UITesting` build in the guest once,
then run `UXREVIEW_UI_REAL_CAPTURE=1 scripts/vm-ui-e2e.sh`. Because guest builds are ad hoc
signed, the grant can stop applying after a rebuild. Without the grant, the suite records a
skip, or fails when the lane is required, exactly as on the host.

## What the automated suite exercises

Tests launch the normal app and click its real menu bar extra. They open Settings, change
controls, enter the editor through the shipped menu, invoke Add Media with its shipped ⌘⇧O shortcut, import through the real open
panel, annotate with Undo/Redo shortcuts, and open Submit Review from its toolbar button. Submission invokes the installed real
`hotsheet-cli` against an isolated store and verifies the resulting ticket and attached
review files. Existing-ticket submission opens the Recent popup, checks its 10-ticket cap,
selects a suggestion, and reopens it at narrow width before submitting. A separate flow prepares media through the shipped import CLI, then switches
between two real project stores, checks an empty project, adds a ticket, refreshes the popup,
and switches back to confirm suggestions follow the selected project. Popup evidence captures the
native Popover element because it can extend beyond the parent window's frame.
The sidebar flow drags and resets the real divider, checks cross-process numeric preference
updates, fitting at minimum window width, restoration when widened, and persistence after
relaunch. Its wide/narrow editor screenshots retain the surrounding toolbar/canvas/inspector.
The accessibility flow reads the real divider slider's announced width and invokes its public
macOS AX increment/decrement actions, checking saved state and programmatic changes back to
the live control, bounds, fitting, reset and a further edit. A bounded test helper resolves
only the launched test app's element by identifier; it does not substitute model calls.
Direct public AX actions additionally require Accessibility trust for the UI-test runner
itself (`UXReviewUITests-Runner`), beyond XCTest event access. A `process trusted=false`
diagnostic means that grant is missing; do not substitute model calls for the AX check.
Readiness checks wait for observable UI state rather than assuming a fixed
launch or submission delay.

Status-menu helpers require a hittable entry with the same nonempty frame across three
readiness polls within five seconds. They click the ready entry's center, avoiding XCTest's
implicit native menu traversal/reopening; callers assert the destination window and controls. They do not retry
the action or automatically reopen a failed menu. A regression cycles through opening,
snapshotting, selecting Settings, and closing Settings three times; the separate
Settings flow checks persistence across app relaunch. A focused regression dismisses the menu
with Escape, verifies a bounded not-ready result, explicitly reopens it and enters the editor.

A failed readiness assertion retains a small `status-menu-readiness` text attachment with the
requested entry, app/foreground state, best-effort desktop-lock flag, status/menu existence,
and the last entry hit-test/frame/stability sample (`HS2-K0JZP2`). It does not collect other
window titles or retry the click. `desktopLocked=unknown` means the session dictionary did not
expose a lock flag; inspect the run's existing screen recording to distinguish lock/focus
interruption from product behavior. Accessibility can continue finding an app behind a lock
screen, which does not prove its menu can receive physical events. The 2026-10-20 investigation
confirmed a lock screen during one failed status-item click. The original ticket run
(`20261020T062742Z-12459`) shows Safari foregrounded with the menu dismissed while Open UX
Review was being polled. These recordings establish external interruption for those runs;
they do not establish a universal cause for every intermittent failure.

The suite uses live AppKit/SwiftUI windows and controls. The temporary preference file is a shared fixture store; normal app preferences still use UserDefaults. Absolute-path UserDefaults suites become read-only when loaded by another process on the tested runtime, while named domains resolve in separate app/runner containers (`HS2-7HJNAC`). It does not substitute offscreen
previews, synthetic capture results, mocked CLI responses, or a test-only route that opens
the desired window at launch. Headless commands may prepare fixtures or inspect persisted
results; they do not stand in for the UI interaction being tested.

Each run uses temporary resources:

| Resource | Isolation |
| --- | --- |
| Settings | `UXREVIEW_DEFAULTS_SUITE` names a temporary plist base path. The app and runner read/write it with `FilePreferences`, and fixture cleanup removes it with the run directory |
| Drafts and discarded reviews | `UXREVIEW_DRAFTS_DIR` and `UXREVIEW_TRASH_DIR` point inside the temporary root |
| Destination project | `--project` selects a temporary project; `HOTSHEET_STORE` normally forces its real adjacent `.hs2` store. The project-switching test removes that override and `--project`, sets isolated saved preferences, and uses sibling-store resolution for two isolated projects |
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
