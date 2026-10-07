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
2. **Capture Image ▸** and **Capture Video ▸**. Each submenu names the target it captures
   ("Image of Region"), which is the default target from Settings (§5.3), and offers:
   - **Immediate**: captures now. It shows the global shortcut (§5.2) when that shortcut starts
     exactly this capture (default delay None) and is a letter, digit, or Space.
   - **Delayed [3 s | 10 s]**: a segmented control in the menu row. Choosing a segment closes
     the menu and starts a countdown capture ([04-capture.md](04-capture.md) §4.3).
   - Capture Video also has the **Narrate Next Recording with Microphone** checkbox, which turns
     narration on or off for the next recording only ([04-capture.md](04-capture.md) §4.9).

   Other targets (Screen, Window, Region) and the 5 s delay are in the app menu bar's
   **Capture** menu (§5.1.1), or set them as the default in Settings.
3. **Settings…** (⌘,) opens the Settings window.
4. **Open UX Review** opens the UX Review window (the annotation editor) on the current draft
   review. With no current draft it brings open UX Review windows forward, or, with none open,
   starts a new empty review (**New Review**, §5.1.1).
5. **Quit UX Review** (⌘Q).

The capture submenus are replaced while a capture runs:

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
| **UX Review** | About UX Review; Settings… (⌘,); Hide (⌘H), Hide Others (⌥⌘H), Show All; Quit (⌘Q) |
| **File** | **New Review** (⌘N): a new empty draft becomes current and opens in its own window; the previous draft stays as it is. **Add Media…** (⌘O): images or movies for the front window's draft ([04-capture.md](04-capture.md) §4.12). **Draft Reviews…** (⇧⌘O, [07-review-session.md](07-review-session.md) §7.9). Save (⌘S). **Submit Review…** (⌘↩, [07-review-session.md](07-review-session.md) §7.1). **Show Review in Finder**. Close Window (⌘W) |
| **Edit** | Undo (⌘Z), Redo (⇧⌘Z), Cut, Copy, Paste, Select All, Duplicate (⌘D) |
| **Capture** | Screenshot / Record Video of Screen, Window, or Region; the After Delay submenus with every preset (3, 5, 10 s); the narration checkbox. Replaced by Cancel / Stop / a status line while a capture runs, like the menu bar menu |
| **Window** | Minimize (⌘M), Zoom, Draft Reviews…, Bring All to Front, and the open windows |

File menu items act on the front window's draft: an editor or Submit Review window answers for
its own draft. With another window in front (Draft Reviews, Settings), they act on the current
draft. In a Submit Review window, **Submit Review…** is disabled so ⌘↩ reaches the window's own
Submit button.

The project a review is filed into is chosen when submitting, in the Submit Review window, which
starts on the last project used ([07-review-session.md](07-review-session.md) §7.6).

## 5.2 Global hotkeys

Two system-wide shortcuts start captures from any app (`HS2-SPFXPW`):

| Shortcut | Default | Starts, when idle |
| --- | --- | --- |
| **Capture** | **⌥⇧⌘U** | The default capture: kind, target, and delay from Settings (§5.3) |
| **Record video** | **⌥⇧⌘V** | A video of the default target with the default delay, whatever the default kind is |

So a reviewer who switches between stills and video uses ⌥⇧⌘U for one and ⌥⇧⌘V for the other
without changing the default. When the default kind is Video, both start the same recording.

Apart from what they start, both shortcuts behave the same way, so either one ends what the
other started:

- **Idle**: pressing it starts its capture.
- **Counting down**: pressing it cancels the countdown. The countdown HUD never takes focus,
  so Esc can't reach it.
- **Recording**: pressing it stops the recording and saves it.
- **Picking, capturing, or saving**: it is ignored. The picker handles Esc itself.

The two shortcuts must differ. The Settings recorder refuses the other shortcut's combination
(it beeps and explains, for example "⌥⇧⌘U is already the capture shortcut."), and so does the
headless mode (§5.5). If hand-edited settings hold the same combination twice anyway, only
Capture registers it, and Record video reports it as invalid.

Requirements on each shortcut:

- One key plus modifiers. Allowed keys are letters, digits, F1–F12, Space, and
  `` - = [ ] ; ' , . / \ ` ``.
- At least one of ⌘, ⌃, or ⌥, so typing is never blocked. F-keys may stand alone.

Text forms: the display form is `⌃⌥⇧⌘U` (always in Apple's modifier order). Parsing also
accepts `ctrl+opt+shift+cmd+u` and `Cmd-Shift-U`, case-insensitive.

Each shortcut is registered with Carbon's `RegisterEventHotKey` as **exclusive**, under its own
hotkey id (1 for Capture, 2 for Record video), so presses go to the right action. Each one
has its own status:

| Status | Shown in Settings |
| --- | --- |
| `registered` | "⌥⇧⌘U starts a capture from any app." / "⌥⇧⌘V records a video from any app." |
| `inUse` | Another app (or another UX Review instance) already owns the combination. Choose a different shortcut. |
| `disabled` | No shortcut is set |
| `invalid` / `failed` | The combination is unusable or duplicated, or the system refused it |

Exclusive registration can't detect shortcuts that macOS itself reserves (for example ⇧⌘3–5);
those simply take precedence.

## 5.3 Settings

The Settings window (menu bar menu or app menu › Settings…, ⌘,) has three sections:

- **Default capture**: kind (Screenshot, Video), target (Screen, Window, Region), and delay
  (None, 3, 5, 10 seconds).
  This is what the Capture hotkey does. The Record video hotkey uses the same target and delay,
  and the menu bar menu's Capture Image and Capture Video use the target (§5.1). The default is
  Region with no delay.
- **Video**: **Record microphone narration**, the narration default for recordings (off). The
  Capture Video menu's checkbox can change it for one recording. See [04-capture.md](04-capture.md) §4.9 for the
  Microphone permission flow.
- **Global shortcuts**: one recorder each for **Start default capture** and **Record video**.
  Click one, then press a combination.
  - Esc cancels recording.
  - Delete clears the shortcut.
  - "Clear" also disables it.
  - An unusable combination, or the other shortcut's, beeps and explains why.
  - Both shortcuts are suspended while recording, so pressing one records it instead of
    starting a capture.
  - Each has a status line showing its registration state from §5.2.

Persistence: settings are saved as JSON under the defaults key `captureSettings`:

```json
{"captureHotkey":"⌥⇧⌘U","defaultRequest":{"delaySeconds":0,"kind":"screenshot","target":"region"},"narration":false,"recordHotkey":"⌥⇧⌘V"}
```

- Missing fields take their defaults. Settings saved before `recordHotkey` existed get ⌥⇧⌘V,
  and settings saved before `narration` existed record without narration.
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
                    [--set-target display|window|region] [--set-delay N]
                    [--set-narration on|off]
```

This mode applies and saves the changes, registers both hotkeys exactly as the app would, and
prints JSON: `settings`, `hotkey {status, message}` (Capture), `recordHotkey {status, message}`,
and `defaultCapture`.

- Exit 0 on success.
- Exit 2 on bad arguments, including an unusable hotkey or one that duplicates the other
  shortcut. In that case nothing is saved. Swapping the two in one command is allowed.

`scripts/app-e2e.sh` uses this mode to check persistence across launches (including turning
narration on and off), registration of both
hotkeys, a real conflict for each against a running menu bar instance, and duplicate rejection.
