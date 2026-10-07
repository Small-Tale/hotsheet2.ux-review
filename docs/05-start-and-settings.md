# 05 — Starting a review and settings

Status: implemented on macOS (`HS2-DR107C`). Capture itself is specified in
[04-capture.md](04-capture.md).

## 5.1 Menu bar

The menu bar icon (a viewfinder) opens UX Review's menu. When idle, it lists:

1. **Capture <default>**: for example "Capture Screenshot of Region". It runs the default
   capture (§5.3) and shows the global shortcut when that shortcut is registered and is a
   letter, digit, or Space.
2. **Screenshot of Screen / Window / Region**, and the **Screenshot After Delay** submenu
   ([04-capture.md](04-capture.md) §4.1).
3. **Record Video of Screen / Window / Region**, and the **Record Video After Delay** submenu
   ([04-capture.md](04-capture.md) §4.9).
4. Current review status, **Annotate Current Review…** (⌘E; disabled with no draft; see
   [06-annotation-editor.md](06-annotation-editor.md)), **Show Current Review in Finder**, and
   **Start New Review**.
5. Hot Sheet status, **Choose Project Folder…**, and **Refresh Hot Sheet Status**.
6. **Settings…** (⌘,), the version, and **Quit**.

The capture items are replaced while a capture runs:

- During a countdown, by **Cancel Capture (N s)**.
- While recording, by **Stop Recording (m:ss)**, and the menu bar icon becomes a record symbol.
- While picking, capturing, or saving a recording, by a status line.

## 5.2 Global hotkey

One system-wide shortcut starts the default capture from any app. The default is **⌥⇧⌘U**.

- **Idle**: pressing it starts the default capture.
- **Counting down**: pressing it cancels the countdown. The countdown HUD never takes focus,
  so Esc can't reach it.
- **Recording**: pressing it stops the recording and saves it.
- **Picking, capturing, or saving**: it is ignored. The picker handles Esc itself.

Requirements on the shortcut:

- One key plus modifiers. Allowed keys are letters, digits, F1–F12, Space, and
  `` - = [ ] ; ' , . / \ ` ``.
- At least one of ⌘, ⌃, or ⌥, so typing is never blocked. F-keys may stand alone.

Text forms: the display form is `⌃⌥⇧⌘U` (always in Apple's modifier order). Parsing also
accepts `ctrl+opt+shift+cmd+u` and `Cmd-Shift-U`, case-insensitive.

The shortcut is registered with Carbon's `RegisterEventHotKey` as **exclusive**, which gives
four possible states:

| Status | Shown in Settings |
| --- | --- |
| `registered` | "⌥⇧⌘U starts a capture from any app." |
| `inUse` | Another app (or another UX Review instance) already owns the combination. Choose a different shortcut. |
| `disabled` | No shortcut is set |
| `invalid` / `failed` | The combination is unusable, or the system refused it |

Exclusive registration can't detect shortcuts that macOS itself reserves (for example ⇧⌘3–5);
those simply take precedence.

## 5.3 Settings

The Settings window (menu › Settings…) has two sections:

- **Default capture**: kind (Screenshot, Video), target (Screen, Window, Region), and delay
  (None, 3, 5, 10 seconds).
  This is what the hotkey and the "Capture <default>" item do. The default is Region with no
  delay.
- **Global shortcut**: a recorder. Click it, then press a combination.
  - Esc cancels recording.
  - Delete clears the shortcut.
  - "Clear" also disables it.
  - An unusable combination beeps and explains why.
  - The current shortcut is suspended while recording, so pressing it again records it
    instead of starting a capture.
  - A status line shows the registration state from §5.2.

Persistence: settings are saved as JSON under the defaults key `captureSettings`:

```json
{"captureHotkey":"⌥⇧⌘U","defaultRequest":{"delaySeconds":0,"kind":"screenshot","target":"region"}}
```

- Missing fields take their defaults.
- An explicit `"captureHotkey": null` means disabled.
- An unreadable value falls back to all defaults.

The project folder (`projectDirectory`) lives in the same defaults domain. The domain is the
app's own (`com.smalltale.uxreview`), or the suite named by `UXREVIEW_DEFAULTS_SUITE` (tests).

## 5.4 Not yet

- Separate global hotkeys for screenshot and video: `HS2-SPFXPW`. Today the one hotkey starts
  the default kind and stops recordings.
- First-run onboarding for permissions is `HS2-418QY0`.

## 5.5 Headless settings mode

```
UXReview --settings [--set-hotkey ⌥⇧⌘U|none] [--set-target display|window|region] [--set-delay N]
```

This mode applies and saves the changes, registers the hotkey exactly as the app would, and
prints JSON: `settings`, `hotkey {status, message}`, and `defaultCapture`.

- Exit 0 on success.
- Exit 2 on bad arguments, including an unusable hotkey. In that case nothing is saved.

`scripts/app-e2e.sh` uses this mode to check three things: persistence across launches,
registration, and a real conflict against a running menu bar instance.
