# 06 — Annotation editor

Status: implemented on macOS (`HS2-9H7WZ8`). Freehand smoothing is `HS2-5N1GFW`. Video trim and
annotation time ranges are `HS2-GBM8JN`. Zoom/pan is `HS2-9Y9DDY`.

The editor marks up the captures of a draft review ([04-capture.md](04-capture.md) §4.6). It
writes shapes, notes, and intents into the draft's `review.json`
([02-review-bundle.md](02-review-bundle.md)).

It started from Hot Sheet 2's markup mode (`clients/web/src/components/attachment-gallery.tsx`
in hotsheet2), which offers rectangles, 8 resize handles, numbered labels, and notes in a
prompt. This editor adds:

- every bundle shape
- intents
- an inspector with inline Markdown notes
- crop
- undo/redo
- keyboard editing
- autosave

## 6.1 Opening and layout

**Opening.** The menu bar menu's **Annotate Current Review…** (⌘E while the menu is open)
opens the editor on the current draft.

- With no draft, a HUD says "Nothing to annotate yet".
- Each draft gets one window. Choosing the item again brings that window forward.
- **Open Media for Annotation…** copies existing images or movies into the current draft and
  opens the editor on the first one ([04-capture.md](04-capture.md) §4.12).

**Layout:**

| Area | Contents |
| --- | --- |
| Tool bar | Tools (§6.3), Undo, Redo, **Restore Original** (only while the image is cropped, §6.6), and a status line: "Editing…" / "Saved to draft", the last editor message, or a save error |
| Media strip (left, only with 2+ captures) | Thumbnails (with the current crop) plus a count badge of annotations on each. Click one to show it. Videos are marked |
| Canvas | The current capture fitted to the view (at most 2×) or zoomed (§6.2.1), on a dark backdrop, with annotations drawn on top |
| Inspector (right) | The selected annotation's number, shape, intents, and Markdown note, with Duplicate and Delete buttons. Below that, every annotation on this capture in review order: number, shape, intents, and note preview. Click a row to select it |

Videos show their first frame. You can annotate them, but they have no time range (the whole
clip) until `HS2-GBM8JN`, and they can't be cropped.

**Menu bar app.** UX Review has no visible main menu, so the editor installs a minimal hidden
Edit menu. That lets ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A, ⌘D, ⌘S, and ⌘W work.

- In the note field, ⌘Z undoes typing.
- On the canvas, ⌘Z undoes editor changes.

## 6.2 Drawing and numbering

`AnnotationRenderer` (CoreGraphics, in `UXReviewKit`) draws everything:

| Shape | Drawn as |
| --- | --- |
| `rect` | Outline with a light fill |
| `strike` | Outline with an X across it |
| `freehand` | Path, closed by default with a light fill. Open paths get no fill |
| `arrow` | Polyline with a filled head at its last point |
| `insertion` | A text cursor (I-beam) standing on the point, with a proofreading caret below it |

**Strokes:**

- Every stroke has a dark halo, so it reads on light and dark captures alike.
- A shape is colored by its **primary intent**: the first intent the reviewer added beyond the
  shape's default, otherwise the default. For example, a rect marked `comment, bug` is red.

| Intent | Color |
| --- | --- |
| comment | blue |
| bug | red |
| change | orange |
| insert | green |
| remove | purple |
| move | teal |
| question | yellow |

**Number badges.** Each annotation has a badge with its number, which is its 1-based position
in the whole review. This is the same `#N` the intake ticket uses
([03-hotsheet-integration.md](03-hotsheet-integration.md) §3.3).

- The badge sits diagonally outside the shape's top-left corner, clear of the corner handle.
  For an arrow it sits at the tail; for an insertion, beside the cursor.
- The badge always stays on the image.

**Selection.** The selected shape is drawn thicker and shows its handles:

- `rect` and `strike` (8 squares): corners and edge midpoints. On boxes smaller than 36 pt only
  the corners are drawn, so the shape stays visible. The edge handles still respond.
- `freehand`: a dashed bounding box with the same 8 handles, which scale the outline.
- `arrow`: one round handle per vertex.
- `insertion`: no handles (move it instead).

The same renderer produces the offscreen previews and `--annotate --render-dir` output, so what
tests inspect is what the reviewer sees.

### 6.2.1 Zoom and pan

The canvas fits the capture to the view by default. To mark small details precisely (for
example in a 5K screenshot), zoom in (`HS2-9Y9DDY`):

| Input | Action |
| --- | --- |
| Pinch | Zoom about the pointer |
| ⌘-scroll (trackpad or mouse wheel) | Zoom about the pointer |
| ⌘+ (or ⌘=) / ⌘- | Zoom in / out to the next stop: 5, 10, 25, 33, 50, 67, 100, 150, 200, 300, 400, 600, 800, 1200, 1600 % |
| ⌘0 | Zoom to fit |
| ⌘1 | Actual pixels (100 %) |
| Two-finger double tap | Toggle between fit and actual pixels at the pointer |
| Scroll (two fingers or wheel) | Pan a zoomed capture |
| Space-drag, middle-button drag | Pan (the cursor becomes a hand) |

- **Percent** is relative to actual pixels: 100 % is one capture pixel per screen pixel, so
  on a Retina display 100 % shows a 2× screenshot at its original on-screen size.
- **Tool bar:** the right end has − / percent / + controls. The percent menu offers Zoom to
  Fit, Actual Pixels, Zoom In, and Zoom Out.
- **Shortcuts:** the zoom shortcuts work while the window is key, even if a note field has
  focus.
- **Range:** from 5 % (or the fit, if that is smaller) to 1600 %. Zooming keeps the capture
  pixel under the pointer in place, and the canvas middle for keyboard and tool bar zoom.
- **Panning** stops when a capture edge reaches the canvas padding. A capture smaller than the
  canvas on an axis stays centered on that axis.
- **Resizing** the window keeps the zoom and the pixel at the canvas middle. A fitted capture
  stays fitted.
- **Switching** to another capture returns to fit. Cropping keeps the zoom and re-clamps.
- **Screen-point sizes:** strokes, handles, badges, the 7-point hit tolerance, and the
  6-point minimum shape size (§6.3) stay the same at every zoom.
- **Zoom is a view setting.** It isn't saved in the draft.
- **Implementation:** `CanvasViewport` in `UXReviewKit` holds the layout math (fit, stops,
  anchored zoom, clamped pan) and is unit-tested. The canvas feeds it events.

## 6.3 Tools and gestures

| Tool | Key | Gesture |
| --- | --- | --- |
| Select | V | Click a shape to select it; drag its body to move it; drag a handle to resize. Click empty space to deselect |
| Rectangle | R | Drag a box |
| Freehand | F | Drag a path; the shape is a closed outline |
| Arrow | A | Drag from tail to head |
| Insertion | I | Click where something should be inserted |
| Strike | S | Drag a box over what should be removed |
| Crop | C | Drag the area to keep (§6.6) |

**Drawing:**

- After drawing a shape, the tool returns to Select and the new shape is selected, so its note
  can be typed right away (⏎ focuses the note).
- A click or a tiny drag draws nothing and keeps the tool active.
  - Minimum size: 6 screen points for a box side, 12 for an arrow's length.
  - A freehand path needs 3 distinct points.
- Points outside the image clamp to its edge.

**Moving and resizing:**

- Moves stop at the media edge.
- Resizes never flip a box and never shrink it below the minimum side.

**Picking among overlapping shapes.** Clicks hit within 7 screen points of a stroke or handle.
Inside a filled shape (rect, strike, closed outline) the whole area counts. When shapes
overlap, the winner is, in order:

1. the one whose stroke is nearest,
2. then the smallest,
3. then the most recently drawn.

So a small box drawn inside a big one stays selectable.

## 6.4 Keyboard

| Key | Action |
| --- | --- |
| V R F A I S C | Choose a tool |
| ⌫ / ⌦ | Delete the selection |
| ← → ↑ ↓ | Nudge the selection 1 px (⇧: 10 px) |
| Tab / ⇧Tab | Select the next / previous annotation on this capture (wraps) |
| ⏎, double-click | Focus the selected annotation's note |
| Esc | Cancel the gesture in progress; otherwise return to Select; otherwise deselect |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘D | Duplicate the selection (offset 2 %, with the same note and intents) |
| ⌘S | Save now |
| ⌘+ / ⌘- / ⌘0 / ⌘1, Space-drag | Zoom in / out / fit / actual pixels, pan (§6.2.1) |

Fuller keyboard and VoiceOver access to the canvas is `HS2-M8ZFS0`.

## 6.5 Notes and intents

**Notes.** Each annotation has one Markdown note, edited in the inspector.

**Intent chips.** The inspector shows one chip per intent ([02-review-bundle.md](02-review-bundle.md)
§2.5). Chips show the annotation's *effective* intents. When the stored list is empty, the
shape's default intent is shown as on, with a "default" hint.

`IntentToggle` toggles a chip over the effective set:

- A chip that is on turns off, and one that is off turns on.
- If the result is just the default intent, or empty, it is stored as `[]`. So the last
  intent can't be removed, and the default is never written out explicitly.
- Any other result is stored in canonical order (`comment, bug, change, insert, remove, move,
  question`).

**Examples:**

- On a strike, turning **bug** on stores `[bug, remove]`.
- Turning **bug** off again stores `[]`.
- Any intent can be added to any shape. For example, a rect with `remove` means "delete this
  region".

**Freehand outlines** also get a **Closed outline** checkbox.

## 6.6 Crop

Crop applies to images only.

- Drag with the Crop tool. The outside is dimmed, and a label shows the size in pixels.
- On release, the rectangle snaps outward to whole pixels and clips to the image. It must be at
  least 8 × 8 px. A crop covering the whole image does nothing.

**What a crop does to annotations** (`ImageCrop.transform`):

- Annotations move into the cropped image's coordinates.
- Boxes are clipped to the crop.
- Path points outside it are pulled to its edge.
- Shapes entirely outside it (including ones only touching its edge) are **removed**.
- The status line says how many were removed, for example "Cropped to 1180 × 560 px. Removed 2
  annotations outside the crop." Undo brings them back.

**Crops within a session:**

- Crops compose: a second crop is relative to the first.
- **Restore Original** returns the image to its untouched original, even when it was cropped
  in an earlier session, and maps the annotations back. It is undoable.
- A crop stays undoable after it is saved. Each save rewrites the image file from the
  session's base image, cropped by the current crop.

**Original files.** The first time a capture is ever cropped, its untouched file is kept as
`originals/<filename>` in the draft. `originals/crops.json` (`OriginalsIndex`, `HS2-6PV1N3`)
records the crop that produced the current file, relative to that original:

```json
{"crops": {"capture-1.png": {"height": 200, "width": 300, "x": 20, "y": 20}}, "version": 1}
```

- **Later sessions.** When a session opens, an image with a trusted record uses the original
  as its base, with the recorded crop already applied. This doesn't mark the editor dirty.
  Restore Original, new crops (relative to the original), and undo then work exactly as within
  one session. Each save updates the record. After a restore it records the full image.
- **When a record is trusted:** the original exists, the crop lies inside it, and the current
  file is exactly the crop's size. With no record, an original the same size as the file must
  be identical, so it counts as a full-image record.
- **Otherwise** (an original kept before crops were recorded, or an unreadable, mismatched, or
  other-version index), the image is edited relative to the file as found. The button reads
  **Reset Crop** and returns only to that file. Cropping such an image drops its unknown
  record, and the original is never overwritten.
- Neither `originals/` nor `crops.json` is ever attached to the ticket.
- `media[].pixelWidth/Height` always describe the file as it is now.

## 6.7 History and saving

`AnnotationEditor` is a pure value-type state machine. Its state has these parts:

- **document**: the bundle, plus each image's crop
- **selection**
- **current media**
- **tool**
- **gesture**: drawing, moving, resizing, or cropping
- **undo/redo stacks**

**Rules:**

1. Each committed change is **one undo step**. A gesture commits once, on release. A press that
   changes nothing (a click to select) records nothing.
2. **Esc or an interruption** restores the state from before the gesture began. Interruptions
   are: showing other media, undo or redo mid-drag, or starting a new gesture.
3. **Coalescing:**
   - Consecutive note edits of the same annotation are one step.
   - Consecutive nudges of the same annotation are one step.
   - Selecting anything, undo, or another edit ends the run.
4. **Undo and redo restore** the document, the selection, and the capture that was showing. So
   undoing an edit on another capture jumps back to it.
5. **A new edit clears redo.** History keeps the last 200 steps.
6. **Not undoable:** navigation (showing media, selecting, choosing a tool).
7. **Annotation ids** are `aN`, one past the highest id in the document *or its history*. An id
   is therefore never reused, even after delete then undo.

**Autosave.** Changes autosave to the draft 0.6 s after the last edit (never mid-gesture). The
editor also saves on ⌘S and when the window closes. `EditorSession.save()` runs in this order:

1. Rewrite the image files whose crop changed.
2. Save through `ReviewDraftStore.update`. Under the store's lock, this re-reads `review.json`,
   replaces the annotations, updates edited media sizes, and keeps media appended since the
   editor opened.
3. Merge any such new captures into the editor.

**Captures while the editor is open.** A capture made while the editor is open is picked up
right away (`.reviewDraftChanged` notification).

- New media is also merged into the undo/redo history and the saved state.
- So undo never removes a capture, and a merge alone never marks the editor dirty.

## 6.8 Code

| Piece | Where |
| --- | --- |
| State machine, gestures, crop, intent toggle | `UXReviewKit/Editor/AnnotationEditor.swift`, `AnnotationEditor+Gestures.swift` |
| Pixel ↔ normalized space, handles, hit testing, move/resize | `UXReviewKit/Editor/ShapeGeometry.swift` |
| Crop math | `UXReviewKit/Editor/ImageCrop.swift` |
| Drawing | `UXReviewKit/Editor/AnnotationRenderer.swift` |
| Files: load, display images, video poster, save, crop writes | `UXReviewKit/Editor/EditorSession.swift` |
| Scripted sessions + `--annotate` parsing | `UXReviewKit/Editor/EditorScript.swift` |
| Window, canvas, inspector, model, previews, headless mode | `App/Sources/Editor/` |

## 6.9 Headless modes (tests and scripts)

```
UXReview --annotate SCRIPT.json [--drafts-dir DIR] [--draft NAME] [--render-dir DIR]
```

**What it does.** Runs an `EditorScript` through the same editor and save path as the window,
on the current draft (or the draft directory named by `--draft`), then saves.

- `--render-dir` writes each capture with its annotations drawn on, as
  `<name>-annotated.png`. A video is drawn on its first frame.
- It prints one JSON object: `status: "annotated"`, `draftDirectory`, `messages` (editor
  status messages, for example crop results), `media`, `annotations` (`number`, `id`,
  `mediaId`, `type`, effective `intents`, `note`), and `rendered`.

**Script format.** A script is `{"steps": [...]}`. Points are media pixels, from the top left.

| Step | Effect |
| --- | --- |
| `{"op": "media", "media": "m2"}` | Show a capture |
| `{"op": "tool", "tool": "rect"}` | Choose a tool (`select`, `rect`, `freehand`, `arrow`, `insertion`, `strike`, `crop`) |
| `{"op": "drag", "points": [[x, y], …]}` | Press at the first point, move through the rest, release. One point is a click |
| `{"op": "cancel-drag", "points": …}` | The same, but Esc instead of release |
| `{"op": "select", "id": "a2"}` / `"#2"` / no id | Select by id or review number, or deselect |
| `{"op": "note", "text": …}`, `{"op": "intent", "intent": "bug"}`, `{"op": "closed", "closed": false}` | Edit the selection (intent toggles) |
| `{"op": "delete"}`, `{"op": "duplicate"}`, `{"op": "nudge", "dx": 1, "dy": 0}` | Act on the selection |
| `{"op": "crop", "rect": [x, y, w, h]}`, `{"op": "reset-crop"}` (alias `restore-original`) | Crop the current image, or restore it (§6.6) |
| `{"op": "undo"}`, `{"op": "redo"}`, `{"op": "save"}` | History and saving |

| Exit code | `error` | Meaning |
| --- | --- | --- |
| 0 | — | Annotated and saved |
| 2 | `invalidArguments` / `invalidScript` | Bad flags, an unreadable or invalid script, an escaping `--draft` name, or a step that can't run (message `Step N: …`, for example "nothing selected") |
| 3 | `noDraft` | No current draft |
| 5 | `failed` | Reading or writing the draft failed |

**Previews.** `--render-ui-previews DIR` ([04-capture.md](04-capture.md) §4.11) also renders the
editor offscreen through the real views, on a draft of mock app screenshots:

- `editor-empty`
- `editor-annotated` (rect selected)
- `editor-arrow-selected`
- `editor-narrow` (the 900 × 560 minimum)
- `editor-crop-drag`
- `editor-cropped`
- `editor-zoomed` (300 % with a selection, §6.2.1)
