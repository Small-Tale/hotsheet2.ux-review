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
  app-e2e.sh                   drives the built app's headless modes (docs/04 §4.11, docs/06 §6.9, docs/07 §7.8)
  macos-project.sh             XcodeGen → macos/UXReview.xcodeproj (not committed)
macos/
  Package.swift                SwiftPM package UXReviewKit (core, no AppKit)
  project.yml                  XcodeGen spec for UXReview.app (menu bar agent app)
  Signing.xcconfig             code signing: ad hoc unless the gitignored Signing.local.xcconfig sets an identity (docs/01 §1.3)
  Signing.local.xcconfig.example  template for the machine-local signing identity
  Sources/UXReviewKit/
    Model/ReviewBundle.swift       bundle, media, shapes, intents, time ranges, Codable
    Model/BundleValidation.swift   ReviewBundle.validate() rules (docs/02 §2.7)
    Tickets/TicketComposer.swift   intake ticket body + Hot Sheet annotation projection (docs/03 §3.3–3.4)
    Tickets/ReviewSubmitter.swift  validate → write review.json → create ticket → attach batch; steps, resume, attachFailed
    HotSheet/HotSheetCLIClient.swift  HotSheetClient protocol, CreatedTicket (slug + file), CLI transport, HotSheetLocator
    HotSheet/HotSheetStatus.swift     ready/problem detection for UI and --status
    HotSheet/ProcessRunner.swift      Process seam (fakeable in tests)
    Capture/CaptureRequest.swift      kind/target/delay of a capture (docs/04 §4.1)
    Capture/RegionGeometry.swift      AppKit rect → display-local, pixel-snapped capture area
    Capture/WindowSelection.swift     window-server snapshots, pick/frontmost window rules
    Capture/CaptureContextBuilder.swift  CaptureContext mapping, OS version string
    Capture/ImageFiles.swift          PNG read/write, test card image (ImageIO)
    Capture/VideoFileWriter.swift     H.264 .mov writer (AVAssetWriter) + optional AAC narration track, ends at the stop time (docs/04 §4.9)
    Capture/Narration.swift           MicrophoneAccess, NarrationPlan (permission decision), SyntheticAudio tone buffers
    Capture/CapturePhase.swift        capture life-cycle transition rules (docs/04 §4.10)
    Capture/CaptureCommand.swift      `--capture` argument parsing (docs/04 §4.11)
    Review/ReviewDraftStore.swift     draft reviews on disk (docs/04 §4.6)
    Review/MediaImporter.swift        existing images/movies → draft (PNG re-encode, movie copy), `--import` parsing (docs/04 §4.12)
    Review/MediaOpenRouting.swift     Finder Open With / editor drop routing plan (dedupe, all-or-nothing), OpenBatch, `--open-media` parsing (docs/04 §4.12.1)
    Review/ReviewSession.swift        session state machine, SessionIssue rules + messages, DraftSubmitter (docs/07)
    Review/ReviewDraftStore+Session.swift  title/summary, remove a capture, submission.json, delete after submit (docs/07 §7.5)
    Review/SubmitCommand.swift        `--submit` parsing, MediaThumbnail (capture list previews)
    Settings/Hotkey.swift             global hotkey model: parse/display, Carbon codes (docs/05 §5.2)
    Settings/CaptureSettings.swift    settings + KeyValueStoring persistence, HotkeySlot (capture/record, duplicate rules), HotkeyAction
    Settings/SettingsCommand.swift    `--settings` argument parsing (docs/05 §5.5)
    Settings/RecentProjects.swift     recent target projects + persistence (docs/07 §7.6)
    Editor/AnnotationEditor.swift     editor state machine: document, selection, undo/redo, intent toggle (docs/06)
    Editor/AnnotationEditor+Gestures.swift  draw/move/resize/crop gestures, hit testing, crop + reset crop
    Editor/AnnotationEditor+Time.swift  playhead, annotation time ranges, trim + reset trim, TimeFormat (docs/06 §6.10)
    Editor/AnnotationEditor+Timeline.swift  timeline drags (range ends, trim handles), TimelineHitTest, TimeFormat.parse
    Editor/VideoTrim.swift            trimmed movie export (AVAssetExportSession), byte-exact restore, frame cache
    Editor/VideoPlayback.swift        play/pause: AVPlayer on the trimmed clip, player frames, PlaybackRules
    Editor/CanvasViewport.swift       canvas zoom/pan: fit, zoom stops, anchored zoom, clamped pan, AutoScroll near edges (docs/06 §6.2.1)
    Editor/ShapeGeometry.swift        MediaFrame pixel ↔ normalized, handles, hit distance, translate/resize
    Editor/OriginalsIndex.swift       originals/crops.json: crop/trim relative to each kept original, trust rules (docs/06 §6.6, §6.10)
    Editor/ImageCrop.swift            PixelRect snapping, annotation transform into a crop
    Editor/AnnotationRenderer.swift   CoreGraphics drawing of shapes, badges, handles, crop overlay; IntentPalette
    Editor/EditorSession.swift        editor + files: display images, video frames, save (merge), crop + trim writes, originals/
    Editor/EditorScript.swift         JSON editing scripts + `--annotate` parsing (docs/06 §6.9)
  Tests/UXReviewKitTests/      Swift Testing unit + end-to-end tests (docs/TEST-COVERAGE.md)
  App/Resources/Assets.xcassets  StatusBarIcon template vector (menu bar icon, docs/05 §5.1)
  App/Sources/
    UXReviewApp.swift          @main, MenuBarExtra + Settings scenes, StatusBarIcon, hotkey + open-files wiring, headless mode routing
    AppModel.swift             observable status + project chooser (follows project changes)
    AppSettings.swift          project folder (defaults / --project), recent projects, folder panel
    UIPreviews.swift           --render-ui-previews offscreen renders for visual QA
    Capture/CaptureBackend.swift      ScreenCaptureKit + synthetic backends, CaptureFailure
    Capture/CaptureEnvironment.swift  displays, window list, capture context provider
    Capture/CapturePipeline.swift     capture → PNG / recorded movie → draft store
    Capture/VideoRecording.swift      SCStream recorder, microphone recorder (AVCaptureSession → host clock), synthetic recorder
    Capture/CaptureCoordinator.swift  UI flow: permission (+ microphone), pick, countdown, capture, alerts
    Capture/TargetPicker.swift        region drag + window pick overlays
    Capture/CaptureHUD.swift          countdown / saved HUD panel
    Capture/CaptureMenu.swift         capture section of the menu bar menu
    Capture/HeadlessCapture.swift     `--capture` mode with JSON output
    Capture/HeadlessImport.swift      `--import` mode with JSON output (docs/04 §4.12)
    Capture/MediaOpening.swift        AppDelegate `application(_:open:)` batching, `--open-media` mode (docs/04 §4.12.1)
    Settings/GlobalHotkeyCenter.swift Carbon RegisterEventHotKey (exclusive) + press handler
    Settings/SettingsModel.swift      live settings, persistence, hotkey re-registration
    Settings/SettingsView.swift       Settings window + shortcut recorder
    Settings/HeadlessSettings.swift   `--settings` mode with JSON output
    Editor/EditorWindowController.swift  one window per draft, save on close, hidden Edit menu, file drop target (docs/04 §4.12.2)
    Editor/EditorModel.swift          observable wrapper: mutate → redraw + autosave, reload on capture
    Editor/EditorView.swift           tool bar, media strip, layout
    Editor/CanvasAutoScroller.swift   60 Hz auto-scroll timer while a canvas gesture runs near an edge
    Editor/AnnotationCanvas.swift     NSView canvas: mouse/keyboard → editor, drawing via AnnotationRenderer
    Editor/TimelineBar.swift          video timeline: play/pause, typed playhead, scrubber, range grips + trim handles, Trim Start/End; TimeField
    Editor/InspectorView.swift        selected annotation (intents, note) + annotation list
    Editor/HeadlessAnnotate.swift     `--annotate` mode with JSON output
    Editor/EditorPreviews.swift       editor states + mock screenshots for --render-ui-previews
    Review/ReviewSessionWindowController.swift  one Submit Review window per draft (docs/07 §7.1)
    Review/ReviewSessionModel.swift   observable session: draft refresh, autosaved fields, remove, submit off-main
    Review/ReviewSessionView.swift    capture list, title/summary, issues, project, progress, failure, success
    Review/HeadlessSubmit.swift       `--submit` mode with JSON output (docs/07 §7.8)
    Review/ReviewSessionPreviews.swift  session states for --render-ui-previews
linux/, windows/               future native variants (README placeholders)
```
