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
  app-e2e.sh                   drives the built app's headless modes (docs/04 §4.11, docs/06 §6.9, docs/07 §7.8, §7.10)
  macos-project.sh             XcodeGen → macos/UXReview.xcodeproj (not committed)
macos/
  Package.swift                SwiftPM package UXReviewKit (core, no AppKit)
  project.yml                  XcodeGen spec for UXReview.app (menu bar agent app)
  Signing.xcconfig             code signing: ad hoc unless the gitignored Signing.local.xcconfig sets an identity (docs/01 §1.3)
  Signing.local.xcconfig.example  template for the machine-local signing identity
  Sources/UXReviewKit/
    Model/ReviewBundle.swift       bundle, media, shapes, intents, time ranges, Codable
    Model/BundleValidation.swift   ReviewBundle.validate() rules (docs/02 §2.7)
    Tickets/TicketComposer.swift   intake ticket body, existing-ticket note, Hot Sheet annotation projection (docs/03 §3.3–3.5)
    Tickets/TicketPreamble.swift   the editable preamble (AI instructions / existing-ticket intro): standard templates, {{placeholders}}, DraftTicketText (`ticket-text.json`) (docs/07 §7.2.3)
    Tickets/MarkdownBlocks.swift   headings / list items / paragraphs of a short Markdown text, for the rendered ticket text
    Tickets/ReviewSubmitter.swift  validate → write review.json → create ticket → attach batch; steps, resume, attachFailed; add(…) to an existing ticket: attach batch → note, noteFailed; PartialAttach: resume an interrupted attach into the same batch
    HotSheet/HotSheetCLIClient.swift  HotSheetClient protocol, CreatedTicket (slug + file), CLI transport (new, attach with stored names + --batch-id, attachIncomplete, show, edit --note-file, moveToTrash, ai-settings get --json), HotSheetLocator
    HotSheet/HotSheetTicket.swift     an existing ticket from `show` front matter, its file; TicketReference (slug/ULID/path in pasted text)
    HotSheet/HotSheetStatus.swift     ready/problem detection for UI and --status
    HotSheet/ProcessRunner.swift      Process seam (fakeable in tests)
    Capture/CaptureRequest.swift      kind/target/delay of a capture (docs/04 §4.1)
    Capture/RegionGeometry.swift      AppKit rect → display-local, pixel-snapped capture area
    Capture/WindowSelection.swift     window-server snapshots, pick/frontmost window rules, own windows kept in captures (docs/04 §4.3)
    Capture/LiveWindowList.swift      the window pick's window list, re-read while picking (throttle, timer, click) (docs/04 §4.2)
    Capture/PickerKeys.swift          picker keys: Space region ⇄ window, Return whole display, Esc; hints (docs/04 §4.2)
    Capture/PickerFocus.swift         who gets focus back when the target picker ends
    Capture/RecordingDim.swift        dim bands + outline around a region being recorded (docs/04 §4.9)
    Capture/CaptureContextBuilder.swift  CaptureContext mapping, OS version string
    Capture/ImageFiles.swift          PNG read/write, test card image (ImageIO)
    Capture/VideoFileWriter.swift     H.264 .mov writer (AVAssetWriter) + optional AAC narration track, ends at the stop time, records its frame rate as metadata (docs/04 §4.9)
    Capture/Narration.swift           MicrophoneAccess, NarrationPlan (permission decision), SyntheticAudio tone buffers
    Capture/CapturePhase.swift        capture life-cycle transition rules (docs/04 §4.10)
    Capture/CaptureCommand.swift      `--capture` argument parsing (docs/04 §4.11)
    Review/ReviewDraftStore.swift     draft reviews on disk, createEmptyDraft for New Review (docs/04 §4.6)
    Review/DraftEdits.swift           edits.json (image and movie crops + trims until submitting), EditProjection: exact maps, outside rules, clipping (docs/06 §6.6, §6.10)
    Review/DraftEdits+Legacy.swift    migrateLegacyEdits: originals/ + crops.json drafts → edits.json
    Review/ReviewSelection.swift      the part of a review that goes to an existing ticket (what is left out), apply/prune (docs/07 §7.2.2)
    Review/SubmissionPreview.swift    each capture as it will be filed (cropped size, trimmed length, AI-scaled size, annotations left out) for the Submit Review window (docs/07 §7.2)
    Review/SubmissionStaging.swift    applies crops + trims, then AI downscaling, into .submission/ when filing: cropped PNGs, movies trimmed + cropped + scaled in one export (docs/07 §7.5)
    Review/MediaScaling.swift         PixelSize, AIToolSettings (ai-settings JSON), MediaScaleTarget (Claude tiers' resize rule, Codex's OpenAI patch rule (2048 px, 2,500 patches) / 2048 px fallback, even movie sides), ClaudeVisionTier model mapping and Claude-model recognition under any tool (docs/07 §7.5.1)
    Review/MediaImporter.swift        existing images/movies → draft (PNG re-encode, movie copy), `--import` parsing (docs/04 §4.12)
    Review/MediaOpenRouting.swift     Finder Open With / editor drop routing plan (dedupe, all-or-nothing), OpenBatch, `--open-media` parsing (docs/04 §4.12.1)
    Review/ReviewSession.swift        session state machine, SessionIssue rules + messages, DraftSubmitter (docs/07)
    Review/ReviewSession+Destination.swift  new vs existing ticket, TicketLookup states, ticket issues, DraftSubmitter.add (docs/07 §7.2.1, §7.4)
    Review/DraftNumbering.swift       numbering.json: highest capture-N / mN used, so removed captures' names and ids are never reused (docs/07 §7.2)
    Review/ReviewDraftStore+Session.swift  title/summary, remove a capture, submission.json (created ticket, attached names, or a partial attach), delete after submit (docs/07 §7.5)
    Review/ReviewDraftStore+Drafts.swift   list every draft (DraftSummary), discard to the Trash (DraftTrash) or delete immediately, draft-folder safety check (docs/07 §7.9)
    Review/DraftsCommand.swift        `--drafts` / `--discard-draft [--delete]` parsing (docs/07 §7.10)
    Review/SubmitCommand.swift        `--submit` parsing (`--to-ticket`, `--exclude`, `--downscale`), MediaThumbnail (capture list previews: the crop, or the frame at the trim start)
    Settings/Hotkey.swift             global hotkey model: parse/display, Carbon codes (docs/05 §5.2)
    Settings/CaptureSettings.swift    settings (incl. downscaleForAI) + KeyValueStoring persistence, RecordingPointer (pointer/clicks in recordings), HotkeySlot (capture/record, duplicate rules), HotkeyAction
    Settings/SettingsCommand.swift    `--settings` argument parsing (docs/05 §5.5)
    Settings/RecentProjects.swift     recent target projects (at most 10) + persistence, the Change menu's project list (ProjectMenuItem) (docs/07 §7.6)
    Settings/ProductName.swift        full (Hot Sheet 2 UX Review) and short (UX Review) product names (docs/00 §0.0)
    Settings/AppMenus.swift           menu bar menu as MenuEntry lists per phase, MenuShortcut, WindowPresence (docs/05 §5.1)
    Settings/WindowFrameFit.swift     a restored window frame shrunk and moved onto the screen's visible area (docs/05 §5.1.1)
    Editor/AnnotationEditor.swift     editor state machine: document, selection, undo/redo, intent toggle (docs/06)
    Editor/AnnotationEditor+ArrowHeads.swift  setArrowHeads: an arrow's start and end heads, undoable (HS2-HQV9R8)
    Editor/AnnotationEditor+Gestures.swift  draw/move/resize gestures, hit testing
    Editor/AnnotationEditor+Crop.swift  one crop per capture (relative to the original), the Crop tool's canvas space (shows the original), draw/move/resize crop gestures, reset crop (docs/06 §6.6)
    Editor/AnnotationEditor+Time.swift  playhead, annotation time ranges, trim + reset trim, TimeFormat (docs/06 §6.10)
    Editor/AnnotationEditor+Timeline.swift  timeline drags (range ends, trim handles), TimelineHitTest, TimeFormat.parse
    Editor/AnnotationEditor+FrameStep.swift  ← / → frame steps: TimelineStepTarget (last-used timeline target), step rules (docs/06 §6.4, §6.10)
    Editor/FrameGrid.swift            uniform frame grid for frame steps at a movie's expected rate (recorded, constant nominal, or a variable-rate movie's snapped interval) (docs/06 §6.10)
    Editor/AnnotationEditor+Media.swift  syncMedia/dropMedia: follow captures added to or removed from the draft (docs/06 §6.7); media strip selection (clickMedia, mediaToRemove)
    Editor/MediaSelection.swift       media strip multiple selection: click / ⌘-click / ⇧-click rules, removal targets, CaptureRemovalPrompt (docs/06 §6.7.2)
    Editor/VideoTrim.swift            movie export trimmed + cropped + scaled in one pass (AVAssetExportSession async export(to:as:), one AVVideoComposition), byte-exact restore, expected frame rate (recorded metadata, sample cursor + edit list), frame cache
    Editor/VideoPlayback.swift        play/pause: AVPlayer on the trimmed clip, player frames, PlaybackRules
    Editor/CanvasViewport.swift       canvas zoom/pan: fit, zoom stops, anchored zoom, clamped pan, reframe (Crop tool on/off), AutoScroll near edges (docs/06 §6.2.1)
    Editor/FreehandSmoothing.swift    freehand stroke cleanup: resample, corner-preserving bounded smoothing, gentle simplify
    Editor/ShapeGeometry.swift        MediaFrame pixel ↔ normalized, handles, hit distance, translate/resize
    Editor/OriginalsIndex.swift       legacy originals/crops.json and its trust rules, read only to migrate older drafts (docs/06 §6.6)
    Editor/ImageCrop.swift            PixelRect snapping and even sides (video crops), annotation transform into a crop
    Editor/AnnotationRenderer.swift   CoreGraphics drawing of shapes, badges, handles, crop overlay; IntentPalette
    Editor/AnnotationRenderer+ArrowHeads.swift  each arrow end drawn in its ArrowHead style
    Editor/EditorSession.swift        editor + files: display images, video frames, frame rates (now or in the background), save + reload (follow added/removed media), edits.json, exact no-drift save
    Editor/MediaStripWidth.swift      the resizable capture sidebar: width range, drag rule, thumbnail size
    Editor/EditorToast.swift          toasts over the canvas: which message shows, info fades / errors stay (ToastPresenter)
    Editor/EditorScript.swift         JSON editing scripts + `--annotate` parsing (docs/06 §6.9)
  Tests/UXReviewKitTests/      Swift Testing unit + end-to-end tests (docs/TEST-COVERAGE.md)
  App/Resources/Assets.xcassets  StatusBarIcon template vector (menu bar icon, docs/05 §5.1)
  App/Sources/
    UXReviewApp.swift          @main: headless mode routing, else an AppKit NSApplication run loop
    AppDelegate.swift          owns capture + settings, status item, app menu bar; open-files batching; File-menu fallbacks for the current draft (docs/05 §5.1)
    Menus/MenuRendering.swift  MenuEntry → NSMenuItem (CommandMenuItem, MenuChoicesView: the "Capture [Screen | Window | Region]" and "Delay [None | 3 s | 10 s]" pickers), MenuDump for menus.json
    Menus/StatusItemController.swift  menu bar icon (StatusBarIcon) + menu rebuilt from AppMenus.statusMenu on open
    Menus/MainMenu.swift       app menu bar (UX Review, File, Edit, View, Window) shown while a window is open (docs/05 §5.1.1)
    Menus/DockPresence.swift   Dock icon + app menu bar while a UX Review window is open (WindowPresence)
    AppSettings.swift          project folder (defaults / --project), recent projects, folder panel, Downscale for AI + the store's AI size
    UIPreviews.swift           --render-ui-previews offscreen renders for visual QA
    WindowSizing.swift         saved window frames kept on screen; why root views state a minimum size (docs/05 §5.1.1)
    Capture/CaptureBackend.swift      ScreenCaptureKit + synthetic backends, CaptureFailure
    Capture/CaptureEnvironment.swift  displays, window list, capture context provider, CaptureChrome (windows never captured)
    Capture/CapturePipeline.swift     capture → PNG / recorded movie → draft store
    Capture/VideoRecording.swift      SCStream recorder, microphone recorder (AVCaptureSession → host clock), synthetic recorder
    Capture/CaptureCoordinator.swift  UI flow: permission (+ microphone), pick, countdown, capture, alerts
    Capture/TargetPicker.swift        region drag + window pick overlays
    Capture/CaptureHUD.swift          countdown / saved HUD panel
    Capture/RecordingDimOverlay.swift click-through dim window shown during a region recording
    Capture/HeadlessCapture.swift     `--capture` mode with JSON output
    Capture/HeadlessImport.swift      `--import` mode with JSON output (docs/04 §4.12)
    Capture/MediaOpening.swift        `--open-media` headless mode (docs/04 §4.12.1); Finder batching lives in AppDelegate
    Settings/GlobalHotkeyCenter.swift Carbon RegisterEventHotKey (exclusive) + press handler
    Settings/SettingsModel.swift      live settings, persistence, hotkey re-registration
    Settings/SettingsView.swift       Settings window content + shortcut recorder
    Settings/SettingsWindowController.swift  the one Settings window (⌘,)
    Settings/HeadlessSettings.swift   `--settings` mode with JSON output
    Editor/EditorWindowController.swift  the UX Review window: one per draft, save on close, Add Media / Submit / Show in Finder for its draft, file drop target (docs/04 §4.12.2), MediaChooser
    Editor/EditorModel.swift          observable wrapper: mutate → redraw + autosave, reload on capture
    Editor/EditorToolbar.swift        the editor window's native NSToolbar: tool group, Restore Original, Submit Review… (prominent)
    Editor/EditorView.swift           toast overlay, media strip (resizable via StripDivider) (⌘/⇧-click multiple selection), layout
    Editor/CanvasAutoScroller.swift   60 Hz auto-scroll timer while a canvas gesture runs near an edge
    Editor/AnnotationCanvas.swift     NSView canvas: mouse/keyboard → editor (← / → monitor for unedited time fields), drawing via AnnotationRenderer
    Editor/TimelineBar.swift          video timeline: play/pause, typed playhead, scrubber, range grips + trim handles, Trim Start/End; TimeField
    Editor/InspectorView.swift        selected annotation (intents, note) + annotation list
    Editor/HeadlessAnnotate.swift     `--annotate` mode with JSON output
    Editor/EditorPreviews.swift       editor states + mock screenshots for --render-ui-previews
    Editor/EditorPreviews+Crop.swift  the Crop tool's preview states (image and video crops)
    Editor/EditorPreviews+ArrowHeads.swift  every head style and a selected span (editor-arrow-heads)
    Editor/EditorPreviews+Toolbar.swift  the real toolbar on a titled window: editor-toolbar.json, editor-window.png
    Editor/EditorPreviews+Typing.swift  types into the middle of a note through the real text view (editor-note-typing.json)
    Review/ReviewSessionWindowController.swift  one Submit Review window per draft (docs/07 §7.1)
    Review/ReviewSessionModel.swift   observable session: draft refresh, autosaved fields, remove, debounced ticket lookup, submit off-main
    Review/ReviewSessionView.swift    capture list, title/summary, issues, project, ticket, progress, failure, success
    Review/ReviewDestinationView.swift  Ticket section: New ticket / Add to existing ticket, ticket field, lookup status (docs/07 §7.2.1); Ticket text: rendered preamble, click to edit (TicketTextBox, MarkdownPreview, §7.2.3)
    Review/HeadlessSubmit.swift       `--submit` mode with JSON output (docs/07 §7.8)
    Review/ReviewSessionPreviews.swift  session states for --render-ui-previews
    Review/DraftsWindowController.swift  Draft Reviews window (one) + DraftsModel: list, open, annotate, reveal, discard (docs/07 §7.9)
    Review/DraftsView.swift           draft rows (title, Current badge, counts, date, problems) and their buttons; empty state
    Review/DraftDiscarding.swift      discard confirmation, close the draft's editor + session windows, move to the Trash; Delete Immediately confirmation when the Trash refuses
    Review/HeadlessDrafts.swift       `--drafts` / `--discard-draft` modes with JSON output (docs/07 §7.10)
    Review/DraftsPreviews.swift       Draft Reviews window states + the Delete Immediately alert for --render-ui-previews
linux/, windows/               future native variants (README placeholders)
```
