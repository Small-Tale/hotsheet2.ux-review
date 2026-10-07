# 00 — Vision and principles

Status: foundation in place (`HS2-3ZSBZ9`); screenshot and video capture and starting from the menu or hotkey
implemented (`HS2-E89PQR`, `HS2-W68HWK`, `HS2-DR107C`; [04-capture.md](04-capture.md),
[05-start-and-settings.md](05-start-and-settings.md)); the annotation editor implemented (`HS2-9H7WZ8`,
[06-annotation-editor.md](06-annotation-editor.md)); other capture and editing features are tracked in
[README.md](README.md#roadmap).

## 0.1 Problem

Today a UX review means stitching tools together. You use the OS screenshot tools or QuickTime
for instant or delayed screen, window, or region captures. Then you edit or mark up the media
somewhere else, keep notes in a third place, and finally type tickets by hand, re-explaining
each region and attaching files one by one.

## 0.2 Target workflow

1. **Start**: from the menu bar icon or a global hotkey (`HS2-DR107C`,
   [05-start-and-settings.md](05-start-and-settings.md)).
2. **Capture**: screenshots or video of the full screen, a window, or a region, optionally after
   a short delay so menus and hover states can be caught (`HS2-E89PQR`, `HS2-W68HWK`). Several
   captures can belong to one review (`HS2-CRJDJ8`).
3. **Edit and annotate** in place (`HS2-9H7WZ8`, `HS2-5N1GFW`, `HS2-GBM8JN`):
   - trim video, crop images
   - rectangular regions with notes
   - freehand outlines for non-rectangular regions, smoothed without over-simplifying
   - arrow paths with notes (for example "move this here")
   - insertion markers ("insert text here") and strike/X markers ("remove this")
   - time ranges, so a video annotation applies only while it is relevant
   - **intent modifiers** (`comment`, `bug`, `change`, `insert`, `remove`, `move`, `question`)
     that apply to any shape, so a rectangle can mean "remove this" just as a strike marker does
4. **File**: one action creates a Hot Sheet 2 intake ticket that carries every region, timeline,
   note, and capture metadata. The captured media and the canonical `review.json` are attached.
   The ticket tells the AI that absorbs it to create individual tickets and reference the same
   attached media in each ([03-hotsheet-integration.md](03-hotsheet-integration.md)).

## 0.3 Principles

- **Native per platform, one format.** Each OS gets a native app. All of them share the review
  bundle format in `spec/` ([02-review-bundle.md](02-review-bundle.md)). macOS comes first and
  establishes the patterns.
- **Hot Sheet compatible by construction.** Coordinates use Hot Sheet 2's normalized `0…10000`
  media space. Every shape can project onto Hot Sheet's rectangle annotations, and richer shape
  data is never lost: it lives in `review.json`.
- **Headless-capable integration.** Filing works through `hotsheet-cli` with no server running.
  A running Hot Sheet service is used when available (`HS2-K1XT5V`).
- **Human-attributed.** Reviews are filed as `human` actor writes, even if the app was launched
  from an AI session.
- **Testable core.** All logic that isn't UI lives in a library without UI dependencies (on
  macOS, `UXReviewKit`), with unit tests plus end-to-end tests against the real Hot Sheet CLI.
