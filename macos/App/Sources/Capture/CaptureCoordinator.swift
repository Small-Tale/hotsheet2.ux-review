import AppKit
import UXReviewKit

/// Runs captures for the menu bar UI: permission → pick target → countdown → screenshot, or
/// → record until stopped. Only one capture runs at a time; the phase follows the
/// `CapturePhase` transition rules. Spec: docs/04-capture.md.
@MainActor
final class CaptureCoordinator: ObservableObject {
    @Published private(set) var phase: CapturePhase = .idle
    @Published private(set) var lastCapture: CaptureOutcome?
    @Published private(set) var lastError: CaptureFailure?
    /// The menu's narration toggle: overrides the Settings default for the next recording only
    /// (nil = use the default). Spec: docs/04-capture.md §4.9.
    @Published var narrationChoice: Bool?
    /// Whether the recording in progress includes microphone narration.
    @Published private(set) var recordingNarration = false

    let backend: CaptureBackend
    let store: ReviewDraftStore
    private let hud = CaptureHUD()
    private var task: Task<Void, Never>?
    private var recording: ActiveRecording?
    private var recordingContext = CaptureContext()

    /// Shown in the "recording started" HUD so the reviewer knows how to stop.
    var stopHint: @MainActor () -> String = { "Stop from the menu bar" }
    /// The Settings default for narration (`CaptureSettings.narration`).
    var narrationDefault: @MainActor () -> Bool = { false }

    /// Whether the next recording will include narration.
    var narratesNextRecording: Bool { narrationChoice ?? narrationDefault() }

    init(
        backend: CaptureBackend = CaptureBackends.make(),
        store: ReviewDraftStore = ReviewDraftStore(
            root: AppSettings.draftsDirectory(),
            trash: DraftTrash.from(environment: ProcessInfo.processInfo.environment)
        )
    ) {
        self.backend = backend
        self.store = store
    }

    /// Starts a screenshot or recording. Ignored unless idle.
    func start(_ request: CaptureRequest) {
        guard apply(.start(request)) else { return }
        task = Task { await run(request) }
    }

    /// Global hotkey: start the default capture, cancel a countdown, or stop a recording
    /// (docs/05 §5.2).
    func handleHotkey(_ slot: HotkeySlot, settings: CaptureSettings) {
        switch HotkeyAction.decide(phase: phase, settings: settings, slot: slot) {
        case let .start(request): start(request)
        case .cancelCountdown: cancel()
        case .stopRecording: stopRecording()
        case .ignore: break
        }
    }

    /// Cancels a pending countdown (pickers also cancel on Esc). Recordings are stopped, not cancelled.
    func cancel() {
        if phase.isCountingDown { task?.cancel() }
    }

    /// Stops a running recording and saves it to the draft review.
    func stopRecording() {
        guard case let .recording(startedAt) = phase, let recording, apply(.stopRequested) else { return }
        self.recording = nil
        hud.hide()
        Task { await finish(recording, startedAt: startedAt) }
    }

    /// Ends the current draft so the next capture starts a new review.
    func startNewReview() {
        do {
            try store.startNew()
            lastCapture = nil
            // No draft object: only the Draft Reviews window listens for this (its Current badge).
            NotificationCenter.default.post(name: .reviewDraftChanged, object: nil)
            hud.flash("New review started", subtitle: "The next capture starts a new draft.")
        } catch {
            report(.failed(String(describing: error)))
        }
    }

    /// True when there is a draft review to annotate (read each time the menu opens).
    var hasCurrentReview: Bool { (try? store.current()) != nil }

    /// Opens the annotation editor on the current draft review.
    func annotateCurrentReview() {
        do {
            guard let draft = try store.current() else {
                hud.flash("Nothing to annotate yet", subtitle: "Capture a screenshot or video first.")
                return
            }
            try EditorWindowController.show(directory: draft.directory, store: store)
        } catch {
            report(.failed(String(describing: error)))
        }
    }

    /// Lets the reviewer pick existing images or movies, copies them into the current draft
    /// review, and opens the editor on the first one (docs/04 §4.12).
    func openMediaForAnnotation() {
        let panel = NSOpenPanel()
        panel.title = "Open Media for Annotation"
        panel.message = "Choose screenshots, images, or movies to add to the current review."
        panel.prompt = "Annotate"
        panel.allowedContentTypes = MediaImporter.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        openMedia(panel.urls)
    }

    /// Imports files opened from Finder ("Open With", the app icon) or the open panel into the
    /// current draft, all or nothing, and opens the editor on the first one (docs/04 §4.12.1).
    func openMedia(_ urls: [URL]) {
        Task {
            do {
                let (draft, media) = try await MediaOpenRouting.open(urls, into: store)
                NotificationCenter.default.post(name: .reviewDraftChanged, object: draft.directory)
                try EditorWindowController.show(directory: draft.directory, store: store, mediaId: media.first?.id)
            } catch let error as MediaImportError {
                reportImport(error)
            } catch {
                report(.failed(String(describing: error)))
            }
        }
    }

    private func reportImport(_ error: MediaImportError) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't open that media"
        alert.informativeText = "\(error.description) Nothing was added to the review."
        alert.runModal()
    }

    func revealCurrentReview() {
        if let draft = try? store.current() {
            NSWorkspace.shared.activateFileViewerSelecting([lastCapture?.fileURL ?? draft.bundleURL])
        }
    }

    /// Applies a transition; returns false (and changes nothing) when it is not allowed.
    @discardableResult
    private func apply(_ event: CapturePhase.Event) -> Bool {
        guard let next = phase.next(event) else { return false }
        phase = next
        return true
    }

    private func run(_ request: CaptureRequest) async {
        defer { task = nil }
        do {
            guard backend.requestPermission() else { throw CaptureFailure.permissionDenied }
            // Settle narration before picking, so a permission question never interrupts a countdown.
            let narration = request.kind == .video ? try await resolveNarration(requested: narratesNextRecording) : false
            let source = try await TargetPicker.pick(request.target)
            apply(.picked)
            let screen = screen(for: source)
            while case let .countingDown(_, remaining) = phase {
                hud.showCountdown(remaining, on: screen, recording: request.kind == .video)
                try await Task.sleep(for: .seconds(1))
                apply(.tick)
            }
            hud.hide()
            if request.delaySeconds > 0 {
                // Let the HUD leave the screen (it is excluded anyway; this keeps window captures clean).
                try await Task.sleep(for: .milliseconds(150))
            }
            switch request.kind {
            case .screenshot:
                let outcome = try await CapturePipeline(backend: backend, store: store).screenshot(source)
                saved(outcome)
                apply(.finished)
            case .video:
                recordingContext = CaptureContextProvider.context(for: source, displayScale: nil)
                recording = try await backend.startRecording(
                    source,
                    to: CapturePipeline.temporaryMovieURL(),
                    narration: narration
                ) { [weak self] in
                    self?.stopRecording() // the display or window went away: keep what was recorded
                }
                apply(.recordingStarted(Date()))
                recordingNarration = narration
                narrationChoice = nil // the menu toggle applies to one recording
                hud.flash("Recording", subtitle: narration ? "Microphone on. \(stopHint())" : stopHint(), on: screen)
            }
        } catch {
            hud.hide()
            fail(error)
        }
    }

    private func finish(_ recording: ActiveRecording, startedAt: Date) async {
        let narrated = recordingNarration
        recordingNarration = false
        do {
            let video = try await recording.stop()
            let outcome = try CapturePipeline(backend: backend, store: store).addVideo(
                video,
                context: recordingContext,
                startedAt: startedAt
            )
            saved(outcome, narration: narrated ? (video.hasNarration ? "narrated" : "no microphone audio received") : nil)
            apply(.finished)
        } catch {
            fail(error)
        }
    }

    /// Before a narrated recording: asks for Microphone permission the first time; when it is
    /// denied, restricted, or there is no microphone, offers to record without narration.
    /// Returns whether to narrate; throws `.cancelled` when the reviewer cancels.
    private func resolveNarration(requested: Bool) async throws -> Bool {
        var plan = NarrationPlan.decide(requested: requested, access: backend.microphoneAccess(), canPrompt: true)
        if plan == .askPermission {
            NSApp.activate(ignoringOtherApps: true)
            _ = await backend.requestMicrophoneAccess()
            plan = NarrationPlan.decide(requested: true, access: backend.microphoneAccess(), canPrompt: false)
        }
        switch plan {
        case .off, .askPermission: return false
        case .record: return true
        case let .blocked(access):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = access == .unavailable ? "No microphone for narration" : "Microphone permission needed"
            alert.informativeText = (access.problem ?? "") + " You can record this video without narration."
            alert.addButton(withTitle: "Record Without Narration")
            if access == .denied { alert.addButton(withTitle: "Open System Settings") }
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: return false
            case .alertSecondButtonReturn where access == .denied:
                Self.openMicrophoneSettings()
                throw CaptureFailure.cancelled
            default: throw CaptureFailure.cancelled
            }
        }
    }

    private func saved(_ outcome: CaptureOutcome, narration: String? = nil) {
        lastCapture = outcome
        lastError = nil
        NotificationCenter.default.post(name: .reviewDraftChanged, object: outcome.draft.directory)
        let count = outcome.draft.bundle.media.count
        var subtitle = "\(count) capture\(count == 1 ? "" : "s") in this review"
        if let narration { subtitle = "\(narration) · " + subtitle }
        if let duration = outcome.media.durationMs { subtitle = "\(Self.clock(duration)) · " + subtitle }
        hud.flash("Saved \(outcome.media.filename)", subtitle: subtitle)
    }

    private func fail(_ error: Error) {
        let cancelled = error is CancellationError || (error as? CaptureFailure) == .cancelled
        // Cancel and failure are valid transitions before capture; anything later must still
        // never leave the coordinator stuck.
        if !apply(cancelled ? .cancelled : .failed) || !phase.isIdle {
            phase = .idle
        }
        recording = nil
        recordingNarration = false
        guard !cancelled else { return }
        report(error as? CaptureFailure ?? .failed(String(describing: error)))
    }

    private func screen(for source: CaptureSource) -> NSScreen? {
        switch source {
        case let .display(id, _): DisplayDirectory.displays().first { $0.id == id }?.screen
        case .window: NSScreen.main
        }
    }

    /// `m:ss`.
    static func clock(_ milliseconds: Int) -> String {
        String(format: "%d:%02d", milliseconds / 60000, (milliseconds / 1000) % 60)
    }

    private func report(_ failure: CaptureFailure) {
        lastError = failure
        let alert = NSAlert()
        alert.alertStyle = .warning
        if case .microphone = failure {
            alert.messageText = "Microphone unavailable"
            alert.informativeText = failure.description
        } else if failure == .permissionDenied {
            alert.messageText = "Screen Recording permission needed"
            alert.informativeText = failure.description
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.messageText = "Capture failed"
            alert.informativeText = failure.description
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, failure == .permissionDenied {
            Self.openScreenRecordingSettings()
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
