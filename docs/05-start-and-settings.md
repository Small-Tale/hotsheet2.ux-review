# 05 — Starting a review and settings

Status: implemented on macOS (`HS2-DR107C`). Capture itself is specified in
[04-capture.md](04-capture.md).

## 5.1 Menu bar

The menu bar icon opens UX Review's menu. It is a flame inside viewfinder corners (Hot Sheet's
flame, framed for capture), drawn as a template image so it follows the menu bar's light, dark,
and tinted appearances. The vector source is `macos/App/Resources/Assets.xcassets/StatusBarIcon`,
derived from the Hot Sheet 2 design export `docs/design/exports/ux-review-status-bar-icon.svg`
(cropped to its 20-point artwork and sized 18 points). The menu is short (`HS2-80CTK8`); review
work happens in UX Review's own windows (§5.1.1). When idle, it lists:

1. **UX Review <version>** (a heading).
2. **Capture [Screen | Window | Region]** (`HS2-W62GWS`): a segmented control in the menu row
   showing the default target. Choosing a segment makes it the default target, the same setting
   as Settings › Default capture › Capture (§5.3), so it persists and an open Settings window
   follows it (and the global shortcuts use it too). The menu stays open, so the reviewer can go
   on to a capture item.
3. **Delay [None | 3 s | 10 s]** (`HS2-WC6JSH`): the same kind of row for the default delay,
   the same setting as Settings › Default capture › Delay (§5.3). A default delay the row doesn't
   offer (5 s, chosen in Settings) shows as an extra selected segment ("None | 3 s | 5 s | 10 s")
   until a listed delay is chosen, so the row always says what Capture Image will do.
4. **Capture Image** and **Capture Video**: plain items (no submenus) that capture the default
   target with the default delay, read when the item is chosen, so a change in the rows above
   applies at once. A delay starts a countdown ([04-capture.md](04-capture.md) §4.3). Each shows
   its global shortcut (§5.2) when that shortcut starts exactly this capture and is a letter,
   digit, or Space: by default ⌥⇧⌘U on Capture Image and ⌥⇧⌘V on Capture Video.
5. **Narrate Next Recording with Microphone**: a checkbox that turns narration on or off for the
   next recording only ([04-capture.md](04-capture.md) §4.9).

   Every target with every delay preset (including 5 s) is in the app menu bar's **Capture** menu
   (§5.1.1). With Region or Window as the target, the picker itself switches: **Space** toggles
   region ⇄ window and **Return** takes the whole screen ([04-capture.md](04-capture.md) §4.2).
6. **Settings…** (⌘,) opens the Settings window.
7. **Open UX Review** opens the UX Review window (the annotation editor) on the current draft
   review. With no current draft it brings open UX Review windows forward, or, with none open,
   starts a new empty review (**New Review**, §5.1.1).
8. **Quit UX Review** (⌘Q).

The rows from Capture to Narrate are replaced while a capture runs:

- During a countdown, by **Cancel Capture (N s)**.
- While recording, by **Stop Recording (m:ss)** (plus "Recording microphone narration" when
  narrating), and the menu bar icon becomes a record symbol.
- While picking, capturing, or saving a recording, by a status line.

The menu entries are described in UXReviewKit (`AppMenus`) and turned into an `NSMenu` by the
app each time the menu opens.

### 5.1.1 UX Review windows, Dock icon, and app menu bar

UX Review runs as a menu bar app with no Dock icon. While any of its windows is open (a UX
Review editor window, a Submit Review window, Draft Reviews, or Settings, minimized ones
included), it becomes a regular app: it has a **Dock icon**, appears in **⌘-Tab**, accepts
files **dropped on its Dock icon** (like Finder Open With, [04-capture.md](04-capture.md)
§4.12.1), and shows its **app menu bar**. When the last of those windows closes, it goes back to
the menu bar only. Capture overlays, HUDs, and alerts don't count (`WindowPresence`). Clicking
the Dock icon with no window showing does what **Open UX Review** does.

Each draft review has its own UX Review window; other drafts open as separate windows and stay
until closed. The app menu bar:

| Menu | Items |
| --- | --- |
| **UX Review** | About UX Review (the standard About panel, titled with the full name Hot Sheet 2 UX Review; docs/00 §0.0); Settings… (⌘,); Hide (⌘H), Hide Others (⌥⌘H), Show All; Quit (⌘Q) |
| **File** | **New Review** (⌘N): a new empty draft becomes current and opens in its own window; the previous draft stays as it is. **Add Media…** (⌘O): images or movies for the front window's draft ([04-capture.md](04-capture.md) §4.12). **Draft Reviews…** (⇧⌘O, [07-review-session.md](07-review-session.md) §7.9). Save (⌘S). **Submit Review…** (⌘↩, [07-review-session.md](07-review-session.md) §7.1). **Show Review in Finder**. Close Window (⌘W) |
| **Edit** | Undo (⌘Z), Redo (⇧⌘Z), Cut, Copy, Paste, Select All, Duplicate (⌘D), Remove Capture from Review… (asks first), Remove Capture Now (⌘⌫, no confirmation; both act on the media strip selection, [06-annotation-editor.md](06-annotation-editor.md) §6.7.1–§6.7.2) |
| **Capture** | Screenshot / Record Video of Screen, Window, or Region; the After Delay submenus with every preset (3, 5, 10 s); the narration checkbox. Replaced by Cancel / Stop / a status line while a capture runs, like the menu bar menu |
| **Window** | Minimize (⌘M), Zoom, Draft Reviews…, Bring All to Front, and the open windows |

File menu items act on the front window's draft: an editor or Submit Review window answers for
its own draft. With another window in front (Draft Reviews, Settings), they act on the current
draft. In a Submit Review window, **Submit Review…** is disabled so ⌘↩ reaches the window's own
Submit button.

The project a review is filed into is chosen when submitting, in the Submit Review window, which
starts on the last project used ([07-review-session.md](07-review-session.md) §7.6).

## 5.2 Global hotkeys

Three system-wide shortcuts work from any app. Two start captures (`HS2-SPFXPW`), and one
opens UX Review (`HS2-KVMX71`). The app's other shortcuts (⌘N, ⌘O, ⌘↩, …) live in its app
menu bar and work while a UX Review window is in front (§5.1.1).

| Shortcut | Default | Does, when idle |
| --- | --- | --- |
| **Capture** | **⌥⇧⌘U** | The default capture: kind, target, and delay from Settings (§5.3) |
| **Record video** | **⌥⇧⌘V** | A video of the default target with the default delay, whatever the default kind is |
| **Open UX Review** | **⌥⇧⌘E** | Opens the UX Review window, like the menu bar menu's **Open UX Review** (§5.1) |

So a reviewer who switches between stills and video uses ⌥⇧⌘U for one and ⌥⇧⌘V for the other
without changing the default. When the default kind is Video, both start the same recording.

Apart from what they start, both capture shortcuts behave the same way, so either one ends what
the other started:

- **Idle**: pressing it starts its capture.
- **Counting down**: pressing it cancels the countdown. The countdown HUD never takes focus,
  so Esc can't reach it.
- **Recording**: pressing it stops the recording and saves it.
- **Picking, capturing, or saving**: it is ignored. The picker handles Esc itself.

**Open UX Review** never starts, cancels, or stops a capture. It opens the window when idle or
while recording, and is ignored while picking, counting down, capturing, or saving, so the
window can't land in the capture.

**Globally unique.** The defaults use ⌥⇧⌘ plus a letter, a combination apps rarely claim, and
each is registered **exclusively**: if another app already owns it, registration fails, and
Settings shows "already used by another app" so the reviewer can pick another.

The three shortcuts must differ. The Settings recorder refuses another shortcut's combination
(it beeps and explains, for example "⌥⇧⌘U is already the capture shortcut."), and so does the
headless mode (§5.5). If hand-edited settings hold the same combination twice anyway, only the
first slot (Capture, then Record video, then Open UX Review) registers it, and the later one
reports it as invalid.

Requirements on each shortcut:

- One key plus modifiers. Allowed keys are letters, digits, F1–F12, Space, and
  `` - = [ ] ; ' , . / \ ` ``.
- At least one of ⌘, ⌃, or ⌥, so typing is never blocked. F-keys may stand alone.

Text forms: the display form is `⌃⌥⇧⌘U` (always in Apple's modifier order). Parsing also
accepts `ctrl+opt+shift+cmd+u` and `Cmd-Shift-U`, case-insensitive.

Each shortcut is registered with Carbon's `RegisterEventHotKey` as **exclusive**, under its own
hotkey id (1 for Capture, 2 for Record video, 3 for Open UX Review), so presses go to the right action. Each one
has its own status:

| Status | Shown in Settings |
| --- | --- |
| `registered` | "⌥⇧⌘U starts a capture from any app." / "⌥⇧⌘V records a video from any app." / "⌥⇧⌘E opens UX Review from any app." |
| `inUse` | Another app (or another UX Review instance) already owns the combination. Choose a different shortcut. |
| `disabled` | No shortcut is set |
| `invalid` / `failed` | The combination is unusable or duplicated, or the system refused it |

Exclusive registration can't detect shortcuts that macOS itself reserves (for example ⇧⌘3–5);
those simply take precedence.

## 5.3 Settings

The Settings window (menu bar menu or app menu › Settings…, ⌘,) has four sections:

- **Default capture**: kind (Screenshot, Video), target (Screen, Window, Region), and delay
  (None, 3, 5, 10 seconds).
  This is what the Capture hotkey does. The Record video hotkey uses the same target and delay,
  and the menu bar menu's Capture Image and Capture Video use the target (§5.1). The menu bar
  menu's **Capture [Screen | Window | Region]** row changes the same target. The default is
  Region with no delay.
- **Video**:
  - **Record microphone narration**, the narration default for recordings (off). The Capture
    Video menu's checkbox can change it for one recording. See [04-capture.md](04-capture.md)
    §4.9 for the Microphone permission flow.
  - **Show pointer in recordings** (on) and **Show clicks in recordings** (off, a ring at each
    click like QuickTime Player), `HS2-S4GA06`. They apply from the next recording on.
    Screenshots never include the pointer ([04-capture.md](04-capture.md) §4.4, §4.9).
- **Submitting**: **Downscale images and videos for AI** (on, `HS2-PT8PM6`). Captures are filed
  at a size the target project's default AI tool reads well: Claude's own limits, 2048 × 2048
  for Codex, else 2048 px on the longest side. The draft keeps its full-size files. See
  [07-review-session.md](07-review-session.md) §7.5.1. An open Submit Review window follows the
  change.
- **Global shortcuts**: one recorder each for **Start default capture**, **Record video**, and
  **Open UX Review**.
  Click one, then press a combination.
  - Esc cancels recording.
  - Delete clears the shortcut.
  - "Clear" also disables it.
  - An unusable combination, or another shortcut's, beeps and explains why.
  - All shortcuts are suspended while recording, so pressing one records it instead of
    starting a capture.
  - Each has a status line showing its registration state from §5.2.

Persistence: settings are saved as JSON under the defaults key `captureSettings`:

```json
{"captureHotkey":"⌥⇧⌘U","defaultRequest":{"delaySeconds":0,"kind":"screenshot","target":"region"},"downscaleForAI":true,"narration":false,"openReviewHotkey":"⌥⇧⌘E","recordHotkey":"⌥⇧⌘V","showClicksInRecordings":false,"showPointerInRecordings":true}
```

- Missing fields take their defaults. Settings saved before `recordHotkey` existed get ⌥⇧⌘V,
  settings saved before `openReviewHotkey` existed get ⌥⇧⌘E,
  settings saved before `narration` existed record without narration, and settings saved
  before `showPointerInRecordings` / `showClicksInRecordings` existed show the pointer but not
  clicks, and settings saved before `downscaleForAI` existed downscale.
- An explicit `null` for `captureHotkey` or `recordHotkey` means that shortcut is disabled.
- An unreadable value falls back to all defaults.

The project folder (`projectDirectory`) and the recently used project folders (`recentProjects`,
[07-review-session.md](07-review-session.md) §7.6) live in the same defaults domain. The domain is the
app's own (`com.smalltale.uxreview`), or the suite named by `UXREVIEW_DEFAULTS_SUITE` (tests).

## 5.4 Not yet

- First-run onboarding for permissions is `HS2-418QY0`.

## 5.5 Headless settings mode

```
UXReview --settings [--set-hotkey ⌥⇧⌘U|none] [--set-record-hotkey ⌥⇧⌘V|none]
                    [--set-open-hotkey ⌥⇧⌘E|none] [--set-target display|window|region] [--set-delay N]
                    [--set-narration on|off] [--set-show-pointer on|off] [--set-show-clicks on|off]
                    [--set-downscale on|off]
```

This mode applies and saves the changes, registers all three hotkeys exactly as the app would,
and prints JSON: `settings`, `hotkey {status, message}` (Capture), `recordHotkey {status,
message}`, `openReviewHotkey {status, message}`, and `defaultCapture`.

- Exit 0 on success.
- Exit 2 on bad arguments, including an unusable hotkey or one that duplicates another
  shortcut. In that case nothing is saved. Swapping the two in one command is allowed.

`scripts/app-e2e.sh` uses this mode to check persistence across launches (including turning
narration, the pointer, clicks, and Downscale for AI on and off, and that a headless recording uses the saved
pointer settings), registration of all three
hotkeys, a real conflict for each against a running menu bar instance, and duplicate rejection.
