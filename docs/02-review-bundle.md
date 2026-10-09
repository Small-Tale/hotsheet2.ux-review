# 02 — Review bundle format

Status: v1 defined and implemented in `UXReviewKit` (`HS2-3ZSBZ9`). Schema:
`spec/review-bundle.schema.json`. Example: `spec/examples/review-bundle.example.json`.

A review bundle (`schema: "uxreview/bundle/v1"`) is the canonical record of one review session.
It is attached to the Hot Sheet ticket as `review.json`, next to the captured media.

## 2.1 Top level

| Field | Meaning |
| --- | --- |
| `schema` | Always `uxreview/bundle/v1` for this version |
| `id`, `title`, `summary` | Review identity; `summary` is Markdown notes for the whole review |
| `createdAt` | ISO-8601 timestamp |
| `context` | Optional capture context: `appName`, `bundleIdentifier`, `windowTitle`, `url`, `osVersion`, `displayScale` |
| `media[]` | Captured files (at least one) |
| `annotations[]` | Marks on the media (may be empty) |

## 2.2 Media

Each entry has `id`, `filename`, `kind` (`image` or `video`), `pixelWidth`, `pixelHeight`,
`capturedAt`, and, for video, `durationMs` (after trimming). Optional `context` (same fields as
the top-level `context`) records where that capture came from, since one review can span several
apps ([04-capture.md](04-capture.md) §4.5). The top-level `context` describes the review as a
whole and defaults to the first capture's.

- `filename` is unique within the bundle.
- Tickets refer to media as `attachment:<filename>`.

Optional `hasAudio: true` (video only, `HS2-EZN3NG`) says the movie has an audio track, so a
reader knows there is sound to listen to or transcribe:

- A recording sets it when it was made with microphone narration and audio actually arrived
  ([04-capture.md](04-capture.md) §4.9).
- An imported movie sets it when AVFoundation finds any audio track, narration or the app's own
  sound (§4.12).
- Trimming keeps it, because the trimmed movie keeps its audio track
  ([06-annotation-editor.md](06-annotation-editor.md) §6.10).
- Writers omit the field when there is no audio track; they never write `false`. Absent means "no
  audio, or unknown", which is how bundles written before the field read.
- The intake ticket marks such media "with audio" ([03-hotsheet-integration.md](03-hotsheet-integration.md) §3.3).

Optional `scaledFrom {pixelWidth, pixelHeight}` (`HS2-KMB528`) is the capture's size before it
was downscaled for an AI reader when filing ([07-review-session.md](07-review-session.md) §7.5.1),
after any crop. `pixelWidth`/`pixelHeight` are then the filed size.

- Writers set it only on a capture that was scaled; a draft's own `review.json` never has it.
- It tells a reader the attachment shows less detail than the reviewer saw, so it can ask for a
  crop. Annotation coordinates are normalized (§2.3), so they fit either size.
- Both sizes must be positive (`invalidMediaSize`, §2.7).
- The ticket's media line reads "scaled from W×H" (docs/03 §3.3).

Optional `note` (`HS2-KVDDFH`) is the reviewer's Markdown note about the capture as a whole, for
what no single annotation marks (for example "this whole page feels cramped"):

- It is written in the editor's inspector, on the list page of that capture
  ([06-annotation-editor.md](06-annotation-editor.md) §6.5.2).
- Writers omit it when there is no note; they never write an empty string. Absent means no note,
  which is how bundles written before the field read.
- The ticket shows it under the capture's media line (docs/03 §3.3).

## 2.3 Coordinates

Every coordinate is an integer from 0 to 10000, normalized to the media itself (not to the
screen). This is Hot Sheet 2's `MediaAnnotation` space, so projection onto Hot Sheet needs no
conversion. Rectangles must have positive size and lie fully inside the media
(`x + width <= 10000`, `y + height <= 10000`).

## 2.4 Shapes

| `type` | Data | Default intent | Use |
| --- | --- | --- | --- |
| `rect` | `rect {x,y,width,height}` | `comment` | Rectangular region |
| `freehand` | `points[]` (at least 3), `closed` (default `true`) | `comment` | Non-rectangular outline |
| `arrow` | `points[]` (at least 2); `startHead` (default `none`) and `endHead` (default `closed`) | `move` when it points one way, else `comment` | "Move this there", or with other heads a span, a relation, or a line |
| `insertion` | `point {x,y}` | `insert` | Insert something here |
| `strike` | `rect` | `remove` | Remove the struck element |

**Arrow heads** (`HS2-HQV9R8`). Each end of an arrow has its own head: `none`, `open` (a V of
two strokes), `closed` (a filled triangle), `flat` (a bar across the line, as on a span or
dimension line), `openCircle`, or `closedCircle`. The standard arrow, with nothing at the start
and `closed` at the end, writes neither field; writers omit a head that is its default. An arrow
with an arrowhead (`open` or `closed`) at exactly one end and `none` at the other points one way,
and its default intent is `move`. Any other combination (both ends, bars, circles, a plain line)
marks a span or relation, and its default intent is `comment`. In the ticket text, non-standard
heads follow the shape, for example `Shape: arrow (start flat, end flat)`.

Each shape has a bounding box that projects it onto Hot Sheet's rectangle-only annotations:

- Path shapes use the box around their points.
- Zero-size boxes grow to 1 unit.
- Boxes are clamped to the media.

## 2.5 Intents

An annotation's `intents` is a set drawn from `comment`, `bug`, `change`, `insert`, `remove`,
`move`, `question`.

- Intents are **modifiers** that can apply to any shape. For example, a `rect` with `remove`
  means "delete this region".
- An empty list means the shape's default intent from §2.4.

## 2.6 Time ranges

`timeRange {startMs, endMs}` is inclusive and needs `startMs <= endMs`. Equal endpoints mark a
single instant.

- Only video media may have time ranges.
- `endMs` must not exceed the media's `durationMs`.
- Without a range, the annotation applies to the whole clip.
- The editor keeps ranges inside the clip when it is trimmed, and drops annotations whose range
  falls entirely outside it ([06-annotation-editor.md](06-annotation-editor.md) §6.10).

## 2.7 Validation

`ReviewBundle.validate()` returns every violation in a stable order. A bundle must pass
validation before it can be submitted. The checks are:

- unsupported schema
- no media
- duplicate media id or filename
- non-positive pixel size
- duplicate annotation id
- annotation refers to an unknown media id
- shape out of bounds
- too few points for a path shape
- invalid time range
- time range on an image
- time range past the clip's duration

## 2.8 Versioning

Breaking changes bump the schema to a new id (`uxreview/bundle/v2`). Readers reject schemas they
don't know.

Adding an optional field that older bundles simply lack (such as `hasAudio` or a capture's
`note`, §2.2) is not
breaking: the schema id stays `uxreview/bundle/v1`, every older bundle stays valid, and readers
must treat the missing field as its documented default. The JSON Schema lists the new field, so
validate against the current `spec/review-bundle.schema.json`.
