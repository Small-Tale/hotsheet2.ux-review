# 05 — Starting a review and settings

Status: implemented on macOS (`HS2-DR107C`). Capture itself is specified in
[04-capture.md](04-capture.md).

## 5.1 Menu bar

The menu bar icon opens UX Review's menu. It is a flame inside viewfinder corners (Hot Sheet's
flame, framed for capture), drawn as a template image so it follows the menu bar's light, dark,
and tinted appearances. The vector source is `macos/App/Resources/Assets.xcassets/StatusBarIcon`,
derived from the Hot Sheet 2 design export `docs/design/exports/ux-review-status-bar-icon.svg`
(cropped to its 20-point artwork and sized 18 points). When idle, it lists:

1. **Capture <default>**: for example "Capture Screenshot of Region". It runs the default
   capture (§5.3) and shows the global shortcut when that shortcut is registered and is a
   letter, digit, or Space.
2. **Screenshot of Screen / Window / Region**, and the **Screenshot After Delay** submenu
   ([04-capture.md](04-capture.md) §4.1).
3. **Record Video of Screen / Window / Region**, and the **Record Video After Delay** submenu
   ([04-capture.md](04-capture.md) §4.9). The item for the default target shows the
   record-video shortcut (§5.2) when the default delay is None, since that is exactly what the
   shortcut does. Below them, the **Narrate Next Recording with Microphone** checkbox turns
   narration on or off for the next recording only ([04-capture.md](04-capture.md) §4.9).
4. Current review status, **Annotate Current Review…** (⌘E; disabled with no draft; see
   [06-annotation-editor.md](06-annotation-editor.md)), **Open Media for Annotation…** (⌘O;
   existing images and movies, [04-capture.md](04-capture.md) §4.12), **Show Current Review in
   Finder**, and **Start New Review**.
5. Hot Sheet status, **Choose Project Folder…**, and **Refresh Hot Sheet Status**.
6. **Settings…** (⌘,), the version, and **Quit**.

The capture items are replaced while a capture runs:

- During a countdown, by **Cancel Capture (N s)**.
- While recording, by **Stop Recording (m:ss)** (plus "Recording microphone narration" when
  narrating), and the menu bar icon becomes a record symbol.
- While picking, capturing, or saving a recording, by a status line.

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

The Settings window (menu › Settings…) has three sections:

- **Default capture**: kind (Screenshot, Video), target (Screen, Window, Region), and delay
  (None, 3, 5, 10 seconds).
  This is what the Capture hotkey and the "Capture <default>" item do. The Record video hotkey
  uses the same target and delay. The default is Region with no delay.
- **Video**: **Record microphone narration**, the narration default for recordings (off). The
  menu can change it for one recording. See [04-capture.md](04-capture.md) §4.9 for the
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

The project folder (`projectDirectory`) lives in the same defaults domain. The domain is the
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
