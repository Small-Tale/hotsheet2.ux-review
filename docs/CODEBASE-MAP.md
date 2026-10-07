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
  app-e2e.sh                   drives the built app's headless modes (docs/04 §4.11, docs/06 §6.9)
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
    Capture/VideoFileWriter.swift     H.264 .mov writer (AVAssetWriter), ends at the stop time (docs/04 §4.9)
    Capture/CapturePhase.swift        capture life-cycle transition rules (docs/04 §4.10)
    Capture/CaptureCommand.swift      `--capture` argument parsing (docs/04 §4.11)
    Review/ReviewDraftStore.swift     draft reviews on disk (docs/04 §4.6)
    Review/MediaImporter.swift        existing images/movies → draft (PNG re-encode, movie copy), `--import` parsing (docs/04 §4.12)
    Settings/Hotkey.swift             global hotkey model: parse/display, Carbon codes (docs/05 §5.2)
    Settings/CaptureSettings.swift    settings + KeyValueStoring persistence, HotkeySlot (capture/record, duplicate rules), HotkeyAction
    Settings/SettingsCommand.swift    `--settings` argument parsing (docs/05 §5.5)
    Editor/AnnotationEditor.swift     editor state machine: document, selection, undo/redo, intent toggle (docs/06)
    Editor/AnnotationEditor+Gestures.swift  draw/move/resize/crop gestures, hit testing, crop + reset crop
    Editor/CanvasViewport.swift       canvas zoom/pan: fit, zoom stops, anchored zoom, clamped pan (docs/06 §6.2.1)
    Editor/ShapeGeometry.swift        MediaFrame pixel ↔ normalized, handles, hit distance, translate/resize
    Editor/OriginalsIndex.swift       originals/crops.json: crop relative to each kept original, trust rules (docs/06 §6.6)
    Editor/ImageCrop.swift            PixelRect snapping, annotation transform into a crop
    Editor/AnnotationRenderer.swift   CoreGraphics drawing of shapes, badges, handles, crop overlay; IntentPalette
    Editor/EditorSession.swift        editor + files: display images, video poster, save (merge), crop writes, originals/
    Editor/EditorScript.swift         JSON editing scripts + `--annotate` parsing (docs/06 §6.9)
  Tests/UXReviewKitTests/      Swift Testing unit + end-to-end tests (docs/TEST-COVERAGE.md)
  App/Resources/Assets.xcassets  StatusBarIcon template vector (menu bar icon, docs/05 §5.1)
  App/Sources/
    UXReviewApp.swift          @main, MenuBarExtra + Settings scenes, StatusBarIcon, hotkey wiring, headless mode routing
    AppModel.swift             observable status + project chooser
    AppSettings.swift          project folder (defaults / --project), UXREVIEW_DEFAULTS_SUITE
    UIPreviews.swift           --render-ui-previews offscreen renders for visual QA
    Capture/CaptureBackend.swift      ScreenCaptureKit + synthetic backends, CaptureFailure
    Capture/CaptureEnvironment.swift  displays, window list, capture context provider
    Capture/CapturePipeline.swift     capture → PNG / recorded movie → draft store
    Capture/VideoRecording.swift      SCStream recorder + synthetic recorder
    Capture/CaptureCoordinator.swift  UI flow: permission, pick, countdown, capture, alerts
    Capture/TargetPicker.swift        region drag + window pick overlays
    Capture/CaptureHUD.swift          countdown / saved HUD panel
    Capture/CaptureMenu.swift         capture section of the menu bar menu
    Capture/HeadlessCapture.swift     `--capture` mode with JSON output
    Capture/HeadlessImport.swift      `--import` mode with JSON output (docs/04 §4.12)
    Settings/GlobalHotkeyCenter.swift Carbon RegisterEventHotKey (exclusive) + press handler
    Settings/SettingsModel.swift      live settings, persistence, hotkey re-registration
    Settings/SettingsView.swift       Settings window + shortcut recorder
    Settings/HeadlessSettings.swift   `--settings` mode with JSON output
    Editor/EditorWindowController.swift  one window per draft, save on close, hidden Edit menu
    Editor/EditorModel.swift          observable wrapper: mutate → redraw + autosave, reload on capture
    Editor/EditorView.swift           tool bar, media strip, layout
    Editor/AnnotationCanvas.swift     NSView canvas: mouse/keyboard → editor, drawing via AnnotationRenderer
    Editor/InspectorView.swift        selected annotation (intents, note) + annotation list
    Editor/HeadlessAnnotate.swift     `--annotate` mode with JSON output
    Editor/EditorPreviews.swift       editor states + mock screenshots for --render-ui-previews
linux/, windows/               future native variants (README placeholders)
```
