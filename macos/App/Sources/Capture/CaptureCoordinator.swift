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

    let backend: CaptureBackend
    let store: ReviewDraftStore
    private let hud = CaptureHUD()
    private var task: Task<Void, Never>?
    private var recording: ActiveRecording?
    private var recordingContext = CaptureContext()

    /// Shown in the "recording started" HUD so the reviewer knows how to stop.
    var stopHint: @MainActor () -> String = { "Stop from the menu bar" }

    init(
        backend: CaptureBackend = CaptureBackends.make(),
        store: ReviewDraftStore = ReviewDraftStore(root: AppSettings.draftsDirectory())
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
                recording = try await backend.startRecording(source, to: CapturePipeline.temporaryMovieURL()) { [weak self] in
                    self?.stopRecording() // the display or window went away: keep what was recorded
                }
                apply(.recordingStarted(Date()))
                hud.flash("Recording", subtitle: stopHint(), on: screen)
            }
        } catch {
            hud.hide()
            fail(error)
        }
    }

    private func finish(_ recording: ActiveRecording, startedAt: Date) async {
        do {
            let video = try await recording.stop()
            let outcome = try CapturePipeline(backend: backend, store: store).addVideo(
                video,
                context: recordingContext,
                startedAt: startedAt
            )
            saved(outcome)
            apply(.finished)
        } catch {
            fail(error)
        }
    }

    private func saved(_ outcome: CaptureOutcome) {
        lastCapture = outcome
        lastError = nil
        NotificationCenter.default.post(name: .reviewDraftChanged, object: outcome.draft.directory)
        let count = outcome.draft.bundle.media.count
        var subtitle = "\(count) capture\(count == 1 ? "" : "s") in this review"
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
        if failure == .permissionDenied {
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

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
