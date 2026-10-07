# UX Review

**A [Small Tale Inc.](https://github.com/Small-Tale) project.**

UX Review is a native desktop tool for reviewing software UX. You start a review from the menu
bar or a global hotkey, capture screenshots or video (optionally after a short delay), then
trim, crop, and annotate the media: rectangles, freehand outlines, arrows, insertion and strike
markers, each with a note, an intent, and (for video) a time range. One click files everything in
[Hot Sheet 2](https://github.com/Small-Tale/hotsheet2) as an intake ticket. That ticket tells the
AI that picks it up to split the review into individual tickets that reuse the same media.

macOS comes first (Swift, built with Xcode) and sets the patterns. Linux and Windows variants will
follow and share the same review bundle format.

> **Status:** early. The core model, ticket composition, and Hot Sheet CLI submission are
> implemented and tested. The menu bar app captures screenshots and records video of a screen, window, or
> region, optionally after a delay, into a draft review, from its menu or a configurable global hotkey
> ([docs/04-capture.md](docs/04-capture.md), [docs/05-start-and-settings.md](docs/05-start-and-settings.md)). The annotation editor
> marks up a draft with every shape, notes, intents, crop, and undo/redo
> ([docs/06-annotation-editor.md](docs/06-annotation-editor.md)), including screenshots and movies opened from disk. The submission UI is next. See [docs/README.md](docs/README.md) for the roadmap and tickets.

## Repository layout

| Path | What lives there |
| --- | --- |
| `spec/` | Platform-neutral review bundle JSON Schema plus examples. Every client must conform. |
| `macos/` | macOS app: SwiftPM package `UXReviewKit` (core, no AppKit) and the menu bar app (`App/`, XcodeGen `project.yml`). |
| `linux/`, `windows/` | Future native variants (placeholders). |
| `docs/` | Requirements and design docs, the source of truth for behavior. |
| `scripts/` | `check.sh` (the repo gate) and `macos-project.sh` (generates the Xcode project). |

## Getting started (macOS)

Requirements: macOS 14+, Xcode 16+ (Swift 6), plus `brew install xcodegen swiftlint swiftformat`.
You also need Node (for spec validation) and Hot Sheet 2's `hotsheet-cli` on `PATH`, or pointed
to by `HOTSHEET_CLI`.

```sh
scripts/macos-project.sh                 # generate macos/UXReview.xcodeproj, then open it in Xcode
(cd macos && swift test)                 # core unit + end-to-end tests
scripts/check.sh                         # full gate: lint, spec, tests, app build + smoke run
```

So that macOS keeps Screen Recording permission across rebuilds, sign with your Apple Development
identity: copy `macos/Signing.local.xcconfig.example` to `macos/Signing.local.xcconfig` and fill it
in (see [docs/01-architecture.md](docs/01-architecture.md) §1.3, "Code signing and permissions").

To file reviews, the app needs a project folder that has a Hot Sheet 2 store (linked via
`.hotsheet2/store`, a sibling `<project>.hs2`, or `HOTSHEET_STORE`). Choose it from the menu, or
pass `--project <path>`.

## License

[MIT](LICENSE) © Small Tale Inc.
