# 06 — Annotation editor

Status: implemented on macOS (`HS2-9H7WZ8`). Freehand smoothing is `HS2-5N1GFW`. Zoom/pan is
`HS2-9Y9DDY`. Video trim and annotation time ranges are `HS2-GBM8JN` (§6.10). Arrow-key frame steps are
`HS2-8FTZ09` (§6.4, §6.10); since `HS2-BADS0F` every movie, variable-frame-rate ones included,
steps on a uniform grid at its expected frame rate (§6.10). The timeline step buttons and
`,` / `.` keep 0.1 s steps (`HS2-JP7Z4W`, §6.10). The Crop tool shows the original and adjusts one
crop rectangle (`HS2-4N722Z`, §6.6); videos crop with the same tool (`HS2-M03YP2`, §6.6).

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

**Opening.** The editor is the **UX Review window** (`HS2-80CTK8`). The menu bar menu's **Open
UX Review** (or a click on the Dock icon) opens it on the current draft
([05-start-and-settings.md](05-start-and-settings.md) §5.1).

- With no draft, it starts a new empty review, unless editor windows are already open, which it
  brings forward instead.
- **New Review** (File menu, ⌘N) creates an empty draft, makes it current, and opens it in a new
  window. The canvas then says "No captures in this review yet" and how to add some, and the
  inspector says "Add an image or movie to start annotating."
- Each draft gets one window, which stays until closed. Opening it again brings it forward.
- **Add Media…** (File menu, ⌘O; no toolbar button, `HS2-BSDXHA`) adds existing images or movies to *this window's*
  draft, like a drop ([04-capture.md](04-capture.md) §4.12.2), and shows the first one.
- Finder Open With and a drop on the Dock icon add to the current draft and open its editor
  on the first one ([04-capture.md](04-capture.md) §4.12.1).

**Layout:**

| Area | Contents |
| --- | --- |
| Toolbar (the window's native, unified title bar, `HS2-WHP4V1`) | The window title on the left. At the right end, as macOS 26 Liquid Glass items: the tools (§6.3) as one select-one group (it follows R/F/A/I/S/C/V), **Restore Original** (only while the image is cropped or the video trimmed, §6.6, §6.10), and **Submit Review…** (⌘↩), the prominent action: saves, then opens the Submit Review window on this editor's draft ([07-review-session.md](07-review-session.md) §7.1). Undo and redo are in the Edit menu only (⌘Z / ⇧⌘Z, `HS2-0C8ZVN`) |
| Media strip (left, whenever the review has a capture) | Thumbnails (with the current crop) plus a count badge of annotations on each. Click one to show it; ⌘-click and ⇧-click select several (§6.7.2). Videos are marked. The shown thumbnail has a ✕ button, and every thumbnail a **Remove from Review…** context menu item (§6.7.1). **Resizable** (`HS2-AH6HW4`): drag the line between the strip and the canvas (96–320 pt, 112 standard); thumbnails grow with it, the width is kept across windows and launches, a double-click on the line restores the standard width, and VoiceOver adjusts it in 16 pt steps |
| Canvas | The current capture fitted to the view (at most 2×) or zoomed (§6.2.1), on a dark backdrop, with annotations drawn on top. A video shows the frame at the playhead |
| Toasts (top of the canvas) | No status line (`HS2-KJCJWX`). The editor's messages (crop and trim results and hints) show as a toast that fades after 4 seconds; a save error shows as a toast with a warning sign that stays until saving works again. Saving itself (autosave, ⌘S) shows nothing (`EditorToast`, `ToastPresenter`) |
| Timeline (under the canvas, videos only) | Play/pause, frame step, playhead time, **Trim Start** / **Trim End**, and the scrubber with each annotation's time range (§6.10) |
| Inspector (right) | The selected annotation's number, shape, intents, time (videos, §6.10), and Markdown note, with Duplicate and Delete buttons. Below that, every annotation on this capture in review order: number, shape, intents, time range (videos), and note preview. Click a row to select it |

Videos can be trimmed and their annotations given time ranges (§6.10), and cropped like images
(§6.6).

**Menu bar app.** UX Review has no visible main menu, so the editor installs a minimal hidden
Edit menu. That lets ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A, ⌘D, ⌘S, ⌘↩ (Submit Review…, only in the
editor), and ⌘W work.

- In the note field, ⌘Z undoes typing.
- On the canvas, ⌘Z undoes editor changes.

## 6.2 Drawing and numbering

`AnnotationRenderer` (CoreGraphics, in `UXReviewKit`) draws everything:

| Shape | Drawn as |
| --- | --- |
| `rect` | Outline with a light fill |
| `strike` | Outline with an X across it |
| `freehand` | Path, closed by default with a light fill. Open paths get no fill |
| `arrow` | Polyline with a head at each end, by default a filled head at its last point only. Heads: none, open (V), closed (filled triangle), flat (a bar across the line), open circle (the line stops at its edge), closed circle (`HS2-HQV9R8`) |
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
| ⌘+ (or ⌘=) / ⌘- | View › Zoom In / Zoom Out to the next stop: 5, 10, 25, 33, 50, 67, 100, 150, 200, 300, 400, 600, 800, 1200, 1600 % |
| ⌘9 | View › Zoom to Fit |
| ⌘0 | View › Actual Size (100 %, actual pixels) |
| Two-finger double tap | Toggle between fit and actual pixels at the pointer |
| Scroll (two fingers or wheel) | Pan a zoomed capture |
| Space-drag, middle-button drag | Pan (the cursor becomes a hand) |

- **Percent** is relative to actual pixels: 100 % is one capture pixel per screen pixel, so
  on a Retina display 100 % shows a 2× screenshot at its original on-screen size.
- **View menu** (`HS2-8QBS4V`): **Actual Size** (⌘0), **Zoom to Fit** (⌘9), **Zoom In** (⌘+),
  and **Zoom Out** (⌘-), with Preview's shortcuts. The window shows no zoom controls or percent.
  The items work while an editor window is key, even if a note field has focus, and are disabled
  when it shows no capture or another window is key.
- **Range:** from 5 % (or the fit, if that is smaller) to 1600 %. Zooming keeps the capture
  pixel under the pointer in place, and the canvas middle for View menu zoom.
- **Panning** stops when a capture edge reaches the canvas padding. A capture smaller than the
  canvas on an axis stays centered on that axis.
- **Resizing** the window keeps the zoom and the pixel at the canvas middle. A fitted capture
  stays fitted.
- **Switching** to another capture returns to fit. Choosing the Crop tool (which shows the
  original, §6.6), leaving it, or changing the crop keeps the zoom and the same part of the
  capture at the canvas middle, then re-clamps (`CanvasViewport.reframe`); a fitted capture
  stays fitted. Fit, the zoom range, and the pan limits always use what the canvas shows: the
  cropped size, or the original's while the Crop tool shows it.
- **Screen-point sizes:** strokes, handles, badges, the 7-point hit tolerance, and the
  6-point minimum shape size (§6.3) stay the same at every zoom.
- **Zoom is a view setting.** It isn't saved in the draft.
- **Auto-scroll** (`HS2-SF72JS`): while a shape is drawn, moved, or resized (or a crop is
  dragged) on a zoomed capture, the canvas pans when the pointer is within 20 pt of an edge or
  past it. The visible part reveals what lies past that edge, and corners scroll diagonally.
  - **Speed** grows with how deep the pointer is: from 0 at the zone's inner edge to 1500 pt/s
    at 100 pt past it (`AutoScroll.velocity`).
  - **Holding still** keeps scrolling: a 60 Hz timer (`CanvasAutoScroller`) pans and moves the
    gesture to the media point now under the pointer, so the shape keeps following.
  - **Stopping:** scrolling stops at the capture's edge (the usual pan clamp), and ends with the
    gesture (release or Esc). A fitted capture never auto-scrolls.
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
| Crop | C | Shows the original: drag the area to keep, or drag the crop's edges, corners, or inside to adjust it (§6.6). The tool stays chosen |

**Drawing:**

- After drawing a shape, the tool returns to Select and the new shape is selected, so its note
  can be typed right away (⏎ focuses the note).
- A click or a tiny drag draws nothing and keeps the tool active.
  - Minimum size: 6 screen points for a box side, 12 for an arrow's length.
  - A freehand path needs 3 distinct points.
- Points outside the image clamp to its edge.
- **Freehand smoothing** (`HS2-5N1GFW`, `FreehandSmoothing`): a freehand stroke is cleaned up
  as it is drawn, and the preview shows exactly what will be committed.
  - **Resampling:** samples closer than 3 screen points are merged.
  - **Smoothing:** two light [1, 2, 1] / 4 passes remove jitter, but no point moves more than
    1.5 screen points from where it was drawn.
  - **Corners:** a point turning more than 55° (judged against points two samples away) never
    moves, so corners stay sharp.
  - **Simplifying:** near-collinear points within 0.75 screen points of the line through their
    neighbours are dropped. That is a gentle Douglas–Peucker, not aggressive simplification.
  - **Endpoints:** the stroke's ends stay exact. A nearly straight stroke keeps its ends and its
    widest point.
  - **Scale:** sizes are in screen points, so the feel is the same at every zoom.

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
| ⌘⌫ | Remove the selected captures from the review without asking (§6.7.2; not while editing text) |
| ↑ ↓ | Nudge the selection 1 px (⇧: 10 px) |
| ← → | Videos: step one frame (⇧: 10 frames) of the last-used timeline target (see **Arrow keys** below). Otherwise nudge the selection 1 px (⇧: 10 px). Unlike `,` / `.`, these step frames, not 0.1 s |
| Tab / ⇧Tab | Select the next / previous annotation on this capture (wraps) |
| ⏎ with a drawing tool | Insert a default-sized shape at the middle of the visible canvas (see below) |
| ⏎ (Select tool), double-click | Focus the selected annotation's note |
| Esc | Cancel the gesture in progress; otherwise return to Select; otherwise deselect |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘D | Duplicate the selection (offset 2 %, with the same note and intents) |
| ⌘S | Save now |
| ⌘+ / ⌘- / ⌘9 / ⌘0, Space-drag | Zoom in / out / to fit / actual size (View menu), pan (§6.2.1) |
| K | Videos: play / pause (§6.10) |
| , / . (⇧: 1 s) | Videos: step the playhead back / forward 0.1 s, like the timeline's step buttons, whatever the frame rate (§6.10) |
| Home / End | Videos: move the playhead to the start / end |

**Arrow keys** (`HS2-8FTZ09`). ← / → act on what the reviewer used last, the canvas or the
timeline (`AnnotationEditor.arrowKey`, `frameStepTarget`):

- **Timeline targets:** the playhead (scrubbing, typing the playhead time, `,` / `.`, Home / End,
  an inspector target button), the trim start or end (dragging a trim bracket, Trim Start / Trim
  End), or an end of the selected annotation's range (dragging its grip, typing From / To, Set to
  Playhead). After one of these, ← / → step that target frame by frame (§6.10), even while a shape
  is selected.
- **Canvas:** a press on the canvas (selecting, moving, or drawing), inserting a shape with ⏎,
  ⌘D, ↑ / ↓, choosing another annotation (click, Tab, a list row), or showing other media hands
  ← / → back to the canvas: they nudge the selected shape, as on images. With nothing selected on
  a video they step the playhead.
- **Fallback:** a range target whose annotation was deleted, deselected, or set to the whole clip
  falls back to the playhead. Images have no timeline, so ← / → always nudge there.
- **Focus:** text fields keep their arrows while the reviewer types in them. A time field
  (the playhead time, From, To) that has focus but no typed change gives ← / → to the canvas,
  which takes focus, so a field SwiftUI focused on its own never swallows them. When the window
  opens, the canvas takes focus back from such a field. Pressing the scrubber and pressing Return
  in a time field also focus the canvas.

**Drawing without a pointer** (`HS2-M8ZFS0`). Choose a tool (R, F, A, I, S), then press ⏎.
`AnnotationEditor.insertDefaultShape(at:)` adds a shape centered on the middle of what the
canvas shows (so it lands in view when zoomed):

- **Size:** a fifth of the capture's shorter side, kept inside the capture.
- **Shapes:** a square for Rectangle and Strike, a diagonal arrow pointing up and right, the
  point itself for Insertion, and a closed 12-point outline for Freehand.
- **After inserting:** like a drawn shape, it is one undo step, it is selected, and the tool
  returns to Select. The arrow keys then move it (⇧ for 10 px), and ⏎ focuses its note.
- **Crop:** ⏎ only explains that cropping needs a drag.
- **Script:** the op is `insert`.

**VoiceOver.** The canvas is an accessibility group, for example "Annotation canvas,
capture-1.png, 6 annotations". Its help text explains the keys above.

- **Elements:** each annotation showing on the current capture (on a video, at the playhead) is a child element (role description
  "annotation") whose label reads the number, shape, intents, and note, for example
  "Annotation 1: Rectangle, comment, bug. Field label is clipped." An annotation with a time
  range adds it, for example "…, comment, shows 0:01.00–0:02.50. …". On a video the canvas label
  ends with the playhead time, for example "… 2 annotations showing at 0:01.50".
- **Help:** the canvas's help text also explains the ← / → frame steps and the 0.1 s `,` / `.` steps.
- **Timeline:** the scrubber is an adjustable element ("Playhead", value "0:01.50 of 0:03.00");
  VoiceOver's increment and decrement step it 0.1 s.
- **Frame:** the element frame is the shape's bounds plus 8 points, so points and thin
  shapes stay outlineable.
- **Pressing** an element (VO-Space) selects that annotation. The selected element is
  reported as selected, and VoiceOver moves to a shape inserted from the keyboard.
- **Persistence:** elements are kept by annotation id, so VoiceOver's focus survives redraws.
  The canvas posts a layout change after each edit.

## 6.5 Notes and intents

**Notes.** Each annotation has one Markdown note, edited in the inspector. Text can be typed or
changed anywhere in the note: the insertion point stays where the reviewer is typing, and every
keystroke updates the note (`HS2-XCJPTX`).

**Intent chips.** The inspector shows one chip per intent ([02-review-bundle.md](02-review-bundle.md)
§2.5). Chips show the annotation's *effective* intents. When the stored list is empty, the
shape's default intent is shown as on, with a "default" hint.

Clicking a chip (`IntentToggle.clicked`, `HS2-JMPDDW`) depends on the modifier keys:

- **A plain click selects just that intent.** Every other intent turns off. Clicking the only
  selected intent again changes nothing.
- **⌘-click or ⇧-click toggles** the chip over the effective set: a chip that is on turns off,
  and one that is off turns on. This is how an annotation gets several intents.
- Space on a focused chip, and VoiceOver's press, are plain clicks. VoiceOver also offers the
  toggle as a named action on each chip ("Add to intents" / "Remove from intents"), since it
  can't hold a modifier. The chip's tooltip mentions ⌘-click.
- If the result is just the default intent, or empty, it is stored as `[]`. So the last
  intent can't be removed, and the default is never written out explicitly.
- Any other result is stored in canonical order (`comment, bug, change, insert, remove, move,
  question`).
- Each click that changes the intents is one undo step; a click that changes nothing adds no
  history.

**Examples:**

- On a strike, clicking **bug** stores `[bug]`; ⌘-clicking **bug** instead stores
  `[bug, remove]`.
- ⌘-clicking **bug** off again stores `[]`; so does a plain click on **remove**.
- Any intent can be added to any shape. For example, a rect with `remove` means "delete this
  region".

**Freehand outlines** also get a **Closed outline** checkbox.

**Arrows** also get **Arrow heads**: **Start** and **End** menus with None, Open, Closed, Flat,
Open circle, and Closed circle (`HS2-HQV9R8`, docs/02 §2.4). New arrows start as the standard
arrow (None at the start, Closed at the end). Each change is one undo step. An arrow that points
one way defaults to *move*; with any other heads its default intent is *comment*, so its color and
the ticket's intent follow the heads unless the reviewer chose intents. VoiceOver reads
non-standard heads after the shape, for example "Annotation 2: Arrow, start flat, end flat,
comment."

## 6.6 Crop

Images and videos crop alike (videos: `HS2-M03YP2`). Each capture has **one crop, relative to its
original** (the file as captured, `HS2-4N722Z`): a new or adjusted crop replaces the old one;
crops never compose.

**The Crop tool shows the original.** While Crop (C) is chosen, the canvas shows the whole,
uncropped capture with the current crop rectangle on it (the whole capture when uncropped):

- The outside is dimmed, the rectangle has rule-of-thirds guides, corner brackets, and edge bars,
  and a label shows its size in pixels. The status line says "Drag a new crop, or drag the
  crop's edges, corners, or inside to adjust it."
- **Pressing** within 7 screen points of an edge or corner resizes from it (where two edges are
  in reach, the nearer wins); pressing inside a crop moves it; pressing anywhere else drags a
  new rectangle. Uncropped, the capture's own edges resize, so dragging one in crops that side.
- **The pointer shows what a press would grab** (`HS2-9RRP8G`, `CanvasCursor`), from the same
  hit test and tolerance as the press: a left-right resize cursor on the left and right edges,
  up-down on the top and bottom, a diagonal one on each corner (`NSCursor.frameResize`), an
  open hand inside a crop, and a crosshair elsewhere (a new rectangle). While a crop is being
  moved the hand is closed, while resizing the grabbed edge's or corner's cursor stays wherever
  the pointer goes, and while drawing a new rectangle it is a crosshair. The cursor follows the
  pointer, and also the crop and zoom when they change under a still pointer (undo, zoom keys).
  Space-pan shows the hand as with every tool. (Live pointer check: `HS2-GADPT1`.)
- **Moving** goes by whole pixels and stops at the capture's edges. **Resizing** never flips the
  rectangle or makes it narrower than 8 px.
- **On release** the rectangle snaps outward to whole pixels and clips to the capture. It must be
  at least 8 × 8 px ("A crop must be at least 8 × 8 pixels."). A click, a drag under 6 screen
  points, or a move by nothing changes nothing and says nothing. A rectangle covering the whole
  capture removes the crop ("Showing the whole capture.").
- **The tool stays Crop** after each rectangle, so it can be tweaked. Esc returns to Select.
- **Annotations** show in their places on the original, all of them (those outside the crop
  under the dim), drawn unselected. They can't be selected, moved, or drawn there; the inspector
  still edits notes and intents, and ⌫ still deletes the selection. VoiceOver lists them at their
  places on the original, and the canvas label adds "Crop tool: the original with the crop, W × H
  px".
- **Videos** show the whole frame at the playhead (playing too), with the same rectangle. A video
  crop is widened to **even** sides on release (`PixelRect.evened`: an odd side grows right or
  down, else left or up at the frame's edge), as H.264 needs, so the filed movie is exactly the
  crop's size and annotations map exactly. One crop covers the whole clip.

**Any other tool shows the cropped capture** (simulated; the file is untouched): fit, zoom and
pan limits, hit testing, drawing, inserting, and nudging all use the cropped size, and points
are pixels of the crop. The media strip thumbnail always shows the crop. A cropped video's frames
are cut as they are drawn (`EditorSession.cropped`), while scrubbing and while playing; the
movie is never rewritten while drafting.

**History:** each committed crop change (new, moved, resized, or out to the whole capture) is
one undo step, and undo shows that capture again. Esc, undo or redo, showing another capture,
or choosing another tool mid-drag abandons the drag and changes nothing. Choosing a tool is
navigation (not undoable). Each capture keeps its own crop.

**Not destructive until submitting** (`HS2-71SSJG`). A crop never changes the capture file and
never deletes annotations while the review is a draft:

- Annotations move with the crop **exactly** (`EditProjection`, an affine map that never clips).
- Annotations entirely outside the crop are **hidden, not removed**. They aren't drawn,
  hit-tested, or exposed to VoiceOver. The inspector lists them dimmed with "Outside the crop ·
  left out when submitting". The status line says how many, for example "Cropped to 1180 × 560
  px. 2 annotations outside the crop are hidden."
- Shapes that stick out of the crop are drawn clipped exactly to the image's edge, images and
  videos alike, as they will be submitted; nothing of them reaches the canvas around it
  (`HS2-JHTAZM`). Number badges and the selection's handles are not clipped, so they stay
  usable at the edge.
- Widening the crop again (Restore Original, then a larger crop) or undo brings hidden
  annotations back unchanged, in any later session.

**Restore Original** (any tool) removes the crop, and on a video the trim too (§6.10), as one undo
step, mapping every annotation back exactly. With the Crop tool chosen, the rectangle becomes the
whole capture again.

**Exact mapping.** A crop change maps each annotation out of the old crop into the original and
then into the new crop (`AnnotationEditor.reproject`), so however often the crop is redrawn,
moved, or resized, an annotation drawn on the original comes back exactly: the original is never
finer than a crop of it, so mapping into a crop and back loses nothing.

**On disk** (`DraftEdits`, `<draft>/edits.json`):

```json
{"crops": {"capture-1.png": {"height": 200, "width": 300, "x": 20, "y": 20},
           "capture-2.mov": {"height": 62, "width": 102, "x": 20, "y": 20}},
 "trims": {"capture-2.mov": {"endMs": 800, "startMs": 0}}, "version": 1}
```

- The capture file is never rewritten while drafting. `review.json` keeps the file's own
  `pixelWidth`/`pixelHeight`, with annotations in the file's coordinates (within 0…10000, so the
  draft validates). `edits.json` records the crop relative to the file, by filename; it is
  removed when nothing is cropped or trimmed.
- **Later sessions** open with the crop applied (`EditProjection.editing`), without marking the
  editor dirty. Saving maps back exactly. An annotation the reviewer didn't change keeps its
  stored shape, so reopening and saving never drifts by rounding.
- A record that doesn't fit its file (outside it, another version, unreadable) is ignored: the
  capture shows uncropped.
- **Submitting** applies the crop ([07-review-session.md](07-review-session.md) §7.5): a cropped
  PNG, or a movie trimmed and cropped in one export (§6.10), is made in a staging folder, and
  annotations are clipped to it
  (`EditProjection.clippedToMedia`: boxes are clipped, points pulled to the edge). Annotations
  entirely outside are left out of the ticket only.
- `edits.json` is never attached.

**Drafts from before `HS2-71SSJG`** kept a cropped file, its untouched original as
`originals/<filename>`, and the crop in `originals/crops.json` (`OriginalsIndex`, trusted only when
the original exists, the crop lies inside it, and the file is exactly the crop's size). Opening
or submitting such a draft converts it once (`ReviewDraftStore.migrateLegacyEdits`): the original
goes back in place, annotations map back exactly, and the crop moves to `edits.json`. Untrusted
records leave the file as it is (the original stays under `originals/`).

## 6.7 History and saving

`AnnotationEditor` is a pure value-type state machine. Its state has these parts:

- **document**: the bundle, plus each image's crop and each video's trim
- **selection**
- **current media**
- **tool**
- **gesture**: drawing, moving, resizing, or cropping (drawing, moving, or resizing the crop)
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
4. **Undo and redo restore** the document, the selection, the capture that was showing, and its
   playhead. So undoing an edit on another capture jumps back to it.
5. **A new edit clears redo.** History keeps the last 200 steps.
6. **Not undoable:** navigation (showing media, selecting, choosing a tool, moving the playhead).
7. **Annotation ids** are `aN`, one past the highest id in the document *or its history*. An id
   is therefore never reused, even after delete then undo.

**Autosave.** Changes autosave to the draft 0.6 s after the last edit (never mid-gesture). The
editor also saves on ⌘S and when the window closes. `EditorSession.save()` runs in this order:

1. Catch up with the draft on disk (`EditorSession.reload()`, below), so a capture removed
   meanwhile gets no crop or trim file and no annotations written back.
2. Rewrite the image files whose crop changed, and the movies whose trim changed (§6.10).
3. Save through `ReviewDraftStore.update`. Under the store's lock, this re-reads `review.json`,
   replaces the annotations (leaving out any on media that is no longer in the draft), updates
   edited media sizes and durations, and keeps media appended since the editor opened.
4. Catch up again with what was saved.

### 6.7.1 Removing a capture in the editor

`HS2-SSM1E7`. A capture can be removed from the review in the UX Review window: the ✕ on the
shown thumbnail, a thumbnail's **Remove from Review…** context menu item, or **Edit › Remove
Capture from Review…** (no shortcut). With several captures selected (§6.7.2) they act on the
whole selection and say so: "Remove 3 Captures from Review…". The ✕ and the context menu of a
selected thumbnail remove the selection; the context menu of a thumbnail outside it removes just
that one. A sheet asks first ("Remove capture-2.png from this review?", or "Remove 3 captures
from this review?", naming how many annotations go with them), because it can't be undone. Then
`EditorSession.removeCaptures`:

1. checks every capture is still in the editor (an unknown one removes nothing), then saves the
   editor once, so unsaved work on the other captures is kept;
2. removes each capture as the review session does (`ReviewDraftStore.removeMedia`: its media
   item, its annotations, its file, and its kept original);
3. catches up, so the editor shows a neighboring capture, or the empty state after the last one.
   If a removal fails partway, the editor still catches up with what was removed.

An open Submit Review window refreshes. The Submit Review window's trash button
does the same from there ([07-review-session.md](07-review-session.md) §7.2).

### 6.7.2 Selecting several captures

`HS2-0TQ6RP`. The media strip selects captures like a Finder list (`MediaSelection`):

- **Click** selects one capture and shows it.
- **⌘-click** adds a capture to the selection, or takes one out. The last selected capture
  can't be taken out.
- **⇧-click** selects the range from the anchor (the last plain- or ⌘-clicked capture) to the
  clicked one, replacing the selection.
- The canvas always shows the **primary** capture: the last one clicked. ⌘-clicking the shown
  capture out shows the next selected capture after it, else the one before.
- Selected thumbnails have an accent outline (the shown one thicker) and, with more than one, a
  tinted background. VoiceOver reports them as selected.
- Anything else that shows another capture (selecting an annotation, undo, a removal) shows it
  alone: the selection is only kept while its primary is shown. Captures removed from the draft
  leave the selection, and an id a later capture reuses is never selected by accident.

**⌘⌫ (Edit › Remove Capture Now)** removes every selected capture **without asking**, through
the same `EditorSession.removeCaptures` (unsaved work on the rest is kept). The item names the
count ("Remove 3 Captures Now"). It is disabled while a text field or text view is being
edited, so ⌘⌫ keeps deleting to the start of the line in the note field. Removing every capture
leaves the empty review, as removing the last capture does.

**Captures added or removed while the editor is open.** The editor follows the draft on disk
(`.reviewDraftChanged` notification, `AnnotationEditor.syncMedia(with:)`). A media item counts
as the same only when its id, file name, and capture time all match: removing the last capture
and capturing again reuses its id and file name, and that is a removal plus an addition.

- **Added** (a capture, a drop, Open With): new media is also merged into the undo/redo
  history and the saved state. So undo never removes a capture, and a merge alone never marks
  the editor dirty.
- **Removed** (the review session's Remove, docs/07 §7.2): the media, every annotation on it,
  and its crop or trim leave the document, the saved state, and the undo/redo history. History
  steps that only changed removed media no longer change anything and are dropped, so every
  remaining undo still does something and undo never brings a removed capture back. A running
  gesture or timeline drag is cancelled, playback of the removed video stops, and when the
  showing capture was removed the editor shows the next one (else the previous, else nothing).
  Edits to other captures, saved or not, are kept.

## 6.8 Code

| Piece | Where |
| --- | --- |
| State machine, gestures, intent chip clicks | `UXReviewKit/Editor/AnnotationEditor.swift`, `AnnotationEditor+Gestures.swift`, `IntentToggle.swift` |
| Crop, the Crop tool's canvas space, crop gestures | `UXReviewKit/Editor/AnnotationEditor+Crop.swift` |
| Canvas cursor rules (Crop tool resize / move cursors) | `UXReviewKit/Editor/CanvasCursor.swift`; AppKit wiring in `App/Sources/Editor/AnnotationCanvas+Cursor.swift` |
| Playhead, time ranges, trim | `UXReviewKit/Editor/AnnotationEditor+Time.swift` |
| ← / → frame steps, last-used timeline target | `UXReviewKit/Editor/AnnotationEditor+FrameStep.swift` |
| Frame grid and expected frame rate | `UXReviewKit/Editor/FrameGrid.swift`; read by `VideoTrim.frameRate` |
| Following captures added or removed while open | `UXReviewKit/Editor/AnnotationEditor+Media.swift` |
| Media strip multiple selection, removal prompt words | `UXReviewKit/Editor/MediaSelection.swift` |
| Movie frames, frame times, and trimmed export | `UXReviewKit/Editor/VideoTrim.swift` |
| Pixel ↔ normalized space, handles, hit testing, move/resize | `UXReviewKit/Editor/ShapeGeometry.swift` |
| Crop math | `UXReviewKit/Editor/ImageCrop.swift` |
| Drawing | `UXReviewKit/Editor/AnnotationRenderer.swift` |
| Files: load, display images, video poster, save, crop writes | `UXReviewKit/Editor/EditorSession.swift` |
| Scripted sessions + `--annotate` parsing | `UXReviewKit/Editor/EditorScript.swift` |
| Window, canvas, timeline, inspector, model, previews, headless mode | `App/Sources/Editor/` (`TimelineBar.swift` is the timeline) |

## 6.9 Headless modes (tests and scripts)

```
UXReview --annotate SCRIPT.json [--drafts-dir DIR] [--draft NAME] [--render-dir DIR]
```

**What it does.** Runs an `EditorScript` through the same editor and save path as the window,
on the current draft (or the draft directory named by `--draft`), then saves.

- `--render-dir` writes each capture with its annotations drawn on, as
  `<name>-annotated.png`. A video is drawn at the playhead if it is the capture showing when the
  script ends, otherwise at its first frame. Only annotations showing at that time are drawn.
- It prints one JSON object: `status: "annotated"`, `draftDirectory`, `messages` (editor
  status messages, for example crop and trim results), `media`, `currentMediaId` and
  `currentTimeMs` (the capture showing at the end and its playhead), `selectedMediaIds` (the media
  strip's selection, §6.7.2), `annotations` (`number`, `id`,
  `mediaId`, `type`, effective `intents`, `note`, and `timeRange` when set), and `rendered`.

**Script format.** A script is `{"steps": [...]}`. Points are media pixels, from the top left:
pixels of the crop, except with the Crop tool on an image, where they are pixels of the original
(so `drag` draws, moves, or resizes the crop exactly as the pointer does, §6.6).

| Step | Effect |
| --- | --- |
| `{"op": "media", "media": "m2"}` | Show a capture |
| `{"op": "tool", "tool": "rect"}` | Choose a tool (`select`, `rect`, `freehand`, `arrow`, `insertion`, `strike`, `crop`) |
| `{"op": "drag", "points": [[x, y], …]}` | Press at the first point, move through the rest, release. One point is a click |
| `{"op": "cancel-drag", "points": …}` | The same, but Esc instead of release |
| `{"op": "select", "id": "a2"}` / `"#2"` / no id | Select by id or review number, or deselect |
| `{"op": "note", "text": …}`, `{"op": "intent", "intent": "bug"}`, `{"op": "closed", "closed": false}` | Edit the selection. `intent` is a chip click: just that intent, or with `"modifier": "command"` / `"shift"` a toggle (§6.5) |
| `{"op": "heads", "start": "flat", "end": "closed"}` | Set the selected arrow's heads (either one may be left out to keep it; fails on other shapes) |
| `{"op": "delete"}`, `{"op": "duplicate"}`, `{"op": "nudge", "dx": 1, "dy": 0}` | Act on the selection |
| `{"op": "insert", "point": [x, y]}` (point optional; default the media center) | ⏎ with the current drawing tool (§6.4) |
| `{"op": "crop", "rect": [x, y, w, h]}`, `{"op": "reset-crop"}` | Set the current image's crop (pixels of the original, replacing any crop; the whole image removes it), or remove it (§6.6) |
| `{"op": "time", "ms": 1500}` | Move the playhead on the current video, as the scrubber does (fails on an image) |
| `{"op": "arrow-key", "key": "right", "shift": true}` | ← / → on the canvas (`shift` optional): a frame step of the last-used timeline target, or a nudge (§6.4) |
| `{"op": "timeline-drag", "handle": "range-end", "ms": [900, 700]}`, `cancel-timeline-drag` | Press a timeline handle (`range-start`, `range-end`, `trim-start`, `trim-end`), drag through those times, then release (or press Esc). Range handles need a selection with a time range |
| `{"op": "play", "ms": 400}` | Play the current video in real time for up to 0…60000 ms, then pause; it stops early at the clip end (fails on an image). The time counts from when the player starts moving (it waits up to 5 s for that), so a slow start on a loaded machine does not shorten the step |
| `{"op": "range", "start": 200, "end": 900}`, `{"op": "range"}` | Set the selection's time range in ms, or make it the whole clip (fails on an image's annotation) |
| `{"op": "trim", "start": 200, "end": 900}`, `{"op": "reset-trim"}` | Keep that part of the current video, or restore its length (§6.10) |
| `{"op": "restore-original"}` | Restore Original: the current capture's crop, and a video's trim (§6.6) |
| `{"op": "remove-media", "media": "m1"}` | Remove a capture from the draft as the review session does, then let the editor catch up (§6.7) |
| `{"op": "remove-capture", "media": "m1"}` | Remove from Review in the editor: save first, then remove (§6.7.1) |
| `{"op": "click-media", "media": "m2", "modifier": "command"}` | Click a media strip thumbnail; `modifier` (optional) is `command` (⌘-click) or `shift` (⇧-click) (§6.7.2) |
| `{"op": "remove-selected-captures"}` | ⌘⌫: remove every selected capture without asking (§6.7.2); fails with no capture |
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
- `editor-intent-single` (#1 after a plain click on **change**: just that intent, §6.5)
- `editor-arrow-heads`: one arrow per head style, and a selected span with its Arrow heads menus
- `editor-narrow` (the 900 × 560 minimum)
- `editor-crop-drag` (a first crop being drawn with the Crop tool)
- `editor-crop-tool` (the crop made: the original with the crop rectangle and its handles, the
  tool still Crop, §6.6)
- `editor-crop-adjust` (its right edge being dragged)
- `editor-cropped` (the same crop after choosing Select: the cropped capture, fitted)
- `editor-multi-select` (both captures selected, the second shown, §6.7.2)
- `editor-zoomed` (300 % with a selection, §6.2.1)
- `editor-keyboard-insert` (R then ⏎ sent as real key events), with the canvas's accessibility
  tree written to `editor-accessibility.json`
- `editor-video-crop-tool` and `editor-video-cropped`: the mock recording below cropped, under the
  Crop tool (the whole frame) and then Select (the cut frame) (§6.6)
- `editor-video-timeline`, `editor-video-narrow`, and `editor-video-trimmed`: a mock screen
  recording with a ranged, an instant, and a whole-clip annotation, the playhead inside the
  first range (§6.10)
- `editor-video-playing`: the same recording while it plays (the pause button showing)
- `editor-autoscroll`: a rectangle drawn on a 5K capture at 200 %, with the pointer held at
  the right edge for 1.5 s of timer ticks (§6.2.1)
- `editor-video-range-drag` and `editor-video-trim-drag`: mid-drag of the selected range's end
  grip, and of the start trim handle (the cut part dimmed)
- `editor-video-frame-step`: the selected range's end grip pressed in place, then ⇧→ and ← sent
  as real key events through the canvas (the range ends at 0:02.90 and the playhead follows)

## 6.10 Video time and trimming

Videos get a timeline under the canvas (`HS2-GBM8JN`). Annotations can be limited to part of
the clip, and the clip itself can be trimmed.

**Playhead.** The canvas shows the frame at the playhead.

- **Moving it:** click or drag the scrubber; the step buttons or `,` / `.` step 0.1 s (⇧: 1 s);
  ← / → step one frame (⇧: 10) once the scrubber is the last-used target (§6.4);
  Home / End jump to the ends. See **Time steps and frame steps** below for why there are two. The time reads `0:01.50 / 0:03.00`, and the playhead time is a
  field: type a time and press Return to move there (see **Typing times** below).
- **Resets:** showing another capture puts it back at 0. It is navigation, so it is not
  undoable, but undo and redo restore the playhead of the step they return to.
- **Frames** come from `AVAssetImageGenerator` with zero tolerance. The clip's end time shows
  the last frame.

**Time steps and frame steps** (`HS2-JP7Z4W`). The editor has two step sizes on purpose:

| Control | Step (⇧) | Moves | Unit |
| --- | --- | --- | --- |
| Timeline step buttons, `,` / `.` | 0.1 s (1 s) | the playhead | time, the same on every movie |
| ← / → | 1 frame (10 frames) | the last-used timeline target: playhead, trim end, or range end (§6.4) | the movie's expected frame rate (below) |

- **Why both:** 0.1 s is a coarse step to skim a clip at a predictable pace, whatever its frame
  rate (3 frames at 30 fps, 6 at 60 fps). Frame steps are the precise unit for placing a trim or
  range end. The reviewer chose to keep 0.1 s for the buttons and `,` / `.` rather than make
  every step a frame.
- **Not snapped:** a 0.1 s step moves exactly 0.1 s from where the playhead is, even between
  frames; the canvas shows the frame showing at that time. A frame step snaps to a frame start.
- **The target:** a step button or `,` / `.` also makes the playhead the last-used target, so
  ← / → then step the playhead frame by frame.
- **Tooltips** say so: "Step back 0.1 s (,  ⇧: 1 s). ← steps one frame", and likewise forward.

**Frame steps** (`HS2-8FTZ09`). ← / → move the last-used timeline target (§6.4) one frame,
⇧← / ⇧→ ten frames:

- **Frames:** steps snap to a uniform grid at the movie's **expected** frame rate, measured in
  ms of the base movie, so a trimmed clip keeps it: frame k starts at ⌈k · 1000 / fps⌉ ms, and
  the grid goes on past the ends (the rules below clamp). Forward goes to the start of a later
  frame; back from inside a frame goes to that frame's start first.
- **Not the recorded samples** (`HS2-BADS0F`): a variable-frame-rate movie (screen recordings
  only get a frame when something changes; some imports) still steps one expected frame at a
  time. A still stretch is many steps, never one jump of seconds; the canvas shows whatever
  frame is showing at that time. Which samples were written is an encoding detail the reviewer
  doesn't need to know.
- **The expected rate** (`FrameGrid.expectedRate`, read by `VideoTrim.loadFrameRate` when
  `EditorSession` opens or picks up a capture), the first that applies:
  1. **Recorded:** UX Review's own recordings store the rate they were made for (30 fps, the
     `SCStream` `minimumFrameInterval`; the synthetic recorder's 10 fps) as QuickTime metadata
     `com.smalltale.uxreview.frame-rate` (`VideoFileWriter.frameRateMetadataKey`, docs/04 §4.9).
     Their samples can't show it: the writer's timestamps follow the host clock, and AVFoundation's
     `nominalFrameRate` for such a track is only the average (a mostly still recording reads as
     a few fps).
  2. **Constant rate:** when every video sample sits on the track's nominal rate (within 0.5 ms
     of frame k at k · 1000 / fps), that rate, exactly (29.97 stays 29.97).
  3. **Variable rate, estimated:** otherwise the frame interval is the 10th percentile of the
     gaps between consecutive frame times (gaps under 0.5 ms ignored), so one odd short gap
     doesn't set it. As a rate (at most 240 fps), it snaps to the nearest standard rate (10, 12,
     15, 20, 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 90, 100, 120) within 10 %, else stays
     as it is. An estimate below 9 fps (frames always more than 0.1 s apart) says little about the
     intended rate, so the editor uses 30 fps instead.
  4. **Unknown:** with no readable samples (fewer than two, no sample cursor, or more than
     500,000), the nominal rate; without that, 30 fps.
- **Frame times** for steps 2 and 3 come from the sample table (`AVSampleCursor`, no
  decoding), mapped through each edit of the track's edit list (offset, and scaled by the
  edit's rate); samples outside every edit are left out. An edit's start is not a frame time
  (inside a frame, it would make a short false interval), and times within 0.5 ms of each other
  count once.
- **Loading** (`HS2-F999CM`): the editor window reads each rate in the background
  (`EditorSession.FrameRateLoading.inBackground`), since a movie without a recorded rate has its
  whole sample table read. Until it arrives, steps use 30 fps; then the movie's rate. Steps
  already taken stay where they landed, and the next step goes to a frame of the new grid. A
  rate arriving for a capture removed meanwhile is dropped. Headless `--annotate`, previews,
  and tests read it while the session opens (`.immediately`), so scripts always step the
  movie's rate.
- **Playhead:** clamps to the clip. Navigation, so not undoable.
- **Trim start / end:** trims through the same rules and message as the trim handles. Stepping
  outward brings back trimmed-away time, up to the original's ends; reaching the whole original
  drops the trim (as Restore Original would). The kept clip never gets shorter than the minimum.
  The playhead shows the new first frame (start) or the new end, as after a handle drag.
- **Range ends:** like typing From / To: an end moved past the other drags it along, ends clamp
  to the clip, and the playhead moves to the moved end.
- **Undo:** consecutive steps of the same end are one undo step, like nudges. Another end,
  undo, or any other edit starts a new step. A step abandons a timeline drag in progress.

**Playback** (`HS2-QNFCR0`). **K** or the timeline's play button plays the video from the
playhead, and pauses it again. Space is taken by pan.

- **Following:** the playhead, the annotations showing, and the timeline follow the player
  about 60 times a second. Annotations draw on top of the playing frame as usual.
- **Ends:** playback stops at the clip's end, on its last frame. Play from the end restarts at
  the beginning.
- **Pausing:** any edit pauses first, so gestures, scrubbing, stepping, trims, undo, and
  switching captures act on a still frame. Closing the window also pauses. An autosave doesn't,
  so playing right after an edit keeps playing.
- **Trims:** it plays exactly the clip as trimmed: the session's base movie from the trim start
  to the trim end.
- **Navigation:** like scrubbing, playing is not undoable and doesn't mark the draft dirty. The
  movie's own audio, if any, plays too.
- **Implementation:** `VideoPlayback` in `UXReviewKit` (an `AVPlayer` with an
  `AVPlayerItemVideoOutput` for the frames, and `PlaybackRules` for start, end, and trim
  offset). `EditorModel` owns the player and its timer. The output uses the typed
  `CVPixelBufferAttributes` init and `pixelBufferAndDisplayTime(forItemTime:)` (macOS 26+; the
  dictionary init and `copyPixelBuffer` are deprecated in the macOS 27 SDK).

**Time ranges.** An annotation's `timeRange` ([02-review-bundle.md](02-review-bundle.md) §2.6)
is inclusive, in ms of the clip as trimmed. Equal ends mark an instant. No range means the
whole clip.

- **Default:** new shapes, drawn or inserted, cover the whole clip.
- **Inspector:** the **Time** section has a **Whole clip** checkbox. Unchecking it sets the range
  from the playhead to the end. **From** and **To** are time fields: type a time and press Return.
  Each also has a target button that moves the playhead there, and a **Set to Playhead** button.
  Setting From past To, or To before From, drags the other end along, and the playhead moves to
  the end that was set.
- **Dragging on the timeline** (`HS2-MAH7NK`): the selected annotation's range has white grips
  at both ends in the range lane. Drag one to move that end. The range updates live, and the
  playhead follows the grip so the canvas shows the frame there. Dragging an end past the other
  one turns it into that end (the same clamp-and-swap as `setTimeRange`). An instant can be
  dragged open either way: grab it left of the tick for the start, right of it for the end.
  Release commits **one undo step**, and a drag that ends where it began records nothing.
  Whole-clip annotations have no grips.
- **Rules:** `setTimeRange` clamps to the clip and swaps reversed ends. Each change is one undo
  step. Ranges are refused for images.
- **Showing:** the canvas draws, hit-tests, and exposes to VoiceOver only the annotations whose
  range contains the playhead. A hidden selection stays selected (the inspector still edits it)
  but has no handles.
- **Revealing:** selecting a hidden annotation, from the list, with Tab, or by number, moves the
  playhead to its start.
- **List:** rows on a video show the range (`0:01.00–0:02.00`, one time for an instant, or
  "Whole clip"). Rows hidden at the playhead are dimmed.
- **Timeline:** ranges are drawn under the scrubber in their intent color, numbered when wide
  enough. Instants are thin ticks, and the selection is outlined. Whole-clip annotations aren't
  drawn.

**Trimming.** **Trim Start** cuts everything before the playhead, and **Trim End** cuts everything
after it.

- **Trim handles:** the clip's ends carry `[` and `]` brackets on the scrubber row. Drag one
  inward to preview a trim. The part that would be cut is dimmed, and the playhead follows the
  handle. Nothing changes until release, which trims (through the same rules and message as the
  buttons) as one undo step. The handle never leaves less than the minimum clip. Releasing at
  the clip's end does nothing.
- **Hit rules** (`TimelineHitTest`): presses within 6 pt of a selected range's grip (in the
  range lane) or of a trim bracket (on the scrubber row) grab it, and the pointer shows a
  left-right resize cursor there. A press anywhere else scrubs.
- **Cancelling a drag:** Esc, undo or redo, moving the playhead, showing another capture,
  selecting, or starting a canvas gesture abandons the drag and restores the range and playhead
  from before it. Autosave and playback wait until the drag ends.
- **Exact trims:** type the cut time in the playhead field, then Trim Start or Trim End.

- **Limits:** the kept clip must be at least 100 ms. A trim to the whole clip does nothing.
  Trims are refused for images ("Only videos can be trimmed.").
- **Annotations:** the clip's `durationMs` becomes the kept length. Ranges shift with the clip
  **exactly**, never clamped (`HS2-71SSJG`). A range partly outside shows while the playhead is in
  its kept part; one entirely outside is **hidden, not removed** ("Trimmed to 2.5 s. 1 annotation
  outside the trim is hidden."), listed dimmed in the inspector, and comes back when the trim is
  widened or restored. Whole-clip annotations stay whole-clip. The playhead stays on the same
  frame.
- **Composing:** a second trim is relative to the first. **Restore Original** returns to the full
  length and maps ranges back exactly. It is undoable.
- **Validity:** the draft's `review.json` keeps ranges in the movie's own time, within its
  length. Submitting clamps them into the trimmed clip and leaves out the ones entirely outside.

**Typing times.** Time fields accept `0:01.50`, `1:02.5`, `1:00:02` (hours), `1.5`, `1.5 s`, and
`1500 ms` (`TimeFormat.parse`). Values after a colon must be below 60. Anything else beeps and
the field reverts. After Return, focus goes back to the canvas, so its keys work again.

**Files.** A trim never rewrites the movie while drafting (`HS2-71SSJG`):

- `edits.json` records it under `trims` (ms of the movie, by filename; §6.6), and
  `review.json` keeps the movie's own `durationMs` and ranges in its time. Frames and playback
  come from the movie itself, offset by the trim.
- **Submitting** exports the kept part to the staging folder
  ([07-review-session.md](07-review-session.md) §7.5): `AVAssetExportSession` at the
  highest-quality preset (its async `export(to:as:)`, `HS2-XA294W`), re-encoded so the cut is frame-accurate instead of snapping to key
  frames. A crop (§6.6) is applied in the same pass, before any AI downscaling
  (`VideoTrim.export(_:range:crop:size:to:)`, docs/07 §7.5.1): one video composition whose render
  size is the crop (even sides) or its scaled size, and whose transform is the track's preferred
  transform, a move of the crop's origin to the corner, then the scale, at the movie's frame rate. The container follows the file extension (`.mov`, `.mp4`, `.m4v`). The export keeps
  the audio track (such as narration), so the clip keeps its `hasAudio` flag
  ([02-review-bundle.md](02-review-bundle.md) §2.2).
- **Older drafts** trimmed in place (the original under `originals/` with a `trims` record in
  `originals/crops.json`) convert on open, as crops do (§6.6).
