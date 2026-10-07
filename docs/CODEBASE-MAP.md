# Codebase map

An orientation for people and agents. Update it in the same change that adds a file, a command,
a schema field, or a setting.

```
README.md                      overview, getting started
LICENSE                        MIT © Small Tale Inc.
CLAUDE.md, AGENTS.md           AI-agent workflow (Hot Sheet tickets, testing, commit hygiene)
.swiftformat, .swiftlint.yml   Swift style + lint config (SwiftFormat owns layout)
spec/
  review-bundle.schema.json    canonical cross-platform review bundle schema (docs/02)
  examples/                    schema-valid examples; decoded by every client's tests
docs/                          requirements, source of truth (see docs/README.md)
scripts/
  check.sh                     repo gate: lint, spec, tests, app build + smoke + app e2e
  app-e2e.sh                   drives the built app's headless modes (docs/04 §4.8)
  macos-project.sh             XcodeGen → macos/UXReview.xcodeproj (not committed)
macos/
  Package.swift                SwiftPM package UXReviewKit (core, no AppKit)
  project.yml                  XcodeGen spec for UXReview.app (menu bar agent app)
  Sources/UXReviewKit/
    Model/ReviewBundle.swift       bundle, media, shapes, intents, time ranges, Codable
    Model/BundleValidation.swift   ReviewBundle.validate() rules (docs/02 §2.7)
    Tickets/TicketComposer.swift   intake ticket body + Hot Sheet annotation projection (docs/03 §3.3–3.4)
    Tickets/ReviewSubmitter.swift  validate → write review.json → create ticket → attach batch
    HotSheet/HotSheetCLIClient.swift  HotSheetClient protocol, CLI transport, HotSheetLocator
    HotSheet/HotSheetStatus.swift     ready/problem detection for UI and --status
    HotSheet/ProcessRunner.swift      Process seam (fakeable in tests)
    Capture/CaptureRequest.swift      kind/target/delay of a capture (docs/04 §4.1)
    Capture/RegionGeometry.swift      AppKit rect → display-local, pixel-snapped capture area
    Capture/WindowSelection.swift     window-server snapshots, pick/frontmost window rules
    Capture/CaptureContextBuilder.swift  CaptureContext mapping, OS version string
    Capture/ImageFiles.swift          PNG read/write, test card image (ImageIO)
    Capture/CaptureCommand.swift      `--capture` argument parsing (docs/04 §4.8)
    Review/ReviewDraftStore.swift     draft reviews on disk (docs/04 §4.6)
  Tests/UXReviewKitTests/      Swift Testing unit + end-to-end tests (docs/TEST-COVERAGE.md)
  App/Sources/
    UXReviewApp.swift          @main, MenuBarExtra, --status smoke mode
    AppModel.swift             observable status + project chooser
    AppSettings.swift          project folder (UserDefaults / --project)
    UIPreviews.swift           --render-ui-previews offscreen renders for visual QA
    Capture/CaptureBackend.swift      ScreenCaptureKit + synthetic backends, CaptureFailure
    Capture/CaptureEnvironment.swift  displays, window list, capture context provider
    Capture/CapturePipeline.swift     capture → PNG → draft store
    Capture/CaptureCoordinator.swift  UI flow: permission, pick, countdown, capture, alerts
    Capture/TargetPicker.swift        region drag + window pick overlays
    Capture/CaptureHUD.swift          countdown / saved HUD panel
    Capture/CaptureMenu.swift         capture section of the menu bar menu
    Capture/HeadlessCapture.swift     `--capture` mode with JSON output
linux/, windows/               future native variants (README placeholders)
```
