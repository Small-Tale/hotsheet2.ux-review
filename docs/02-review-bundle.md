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
| `arrow` | `points[]` (at least 2), arrowhead at the last point | `move` | "Move this there" and similar |
| `insertion` | `point {x,y}` | `insert` | Insert something here |
| `strike` | `rect` | `remove` | Remove the struck element |

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
