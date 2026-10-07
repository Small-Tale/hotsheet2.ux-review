import AppKit
import UXReviewKit

/// Runs captures for the menu bar UI: permission → pick target → countdown → capture → save to
/// the draft review → confirm. Only one capture runs at a time. Spec: docs/04-capture.md.
@MainActor
final class CaptureCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case picking
        case countingDown(Int)
        case capturing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCapture: CaptureOutcome?
    @Published private(set) var lastError: CaptureFailure?

    let backend: CaptureBackend
    let store: ReviewDraftStore
    private let hud = CaptureHUD()
    private var task: Task<Void, Never>?

    init(
        backend: CaptureBackend = CaptureBackends.make(),
        store: ReviewDraftStore = ReviewDraftStore(root: AppSettings.draftsDirectory())
    ) {
        self.backend = backend
        self.store = store
    }

    var isBusy: Bool { phase != .idle }

    /// Starts a screenshot. Ignored while another capture is in progress.
    func screenshot(_ request: CaptureRequest) {
        guard !isBusy else { return }
        task = Task { await runScreenshot(request) }
    }

    /// Cancels a pending countdown (or a picker, which also cancels on Esc).
    func cancel() {
        task?.cancel()
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

    func revealCurrentReview() {
        if let draft = try? store.current() {
            NSWorkspace.shared.activateFileViewerSelecting([lastCapture?.fileURL ?? draft.bundleURL])
        }
    }

    private func runScreenshot(_ request: CaptureRequest) async {
        defer {
            phase = .idle
            task = nil
        }
        do {
            guard backend.requestPermission() else { throw CaptureFailure.permissionDenied }
            phase = .picking
            let source = try await TargetPicker.pick(request.target)
            try await countDown(request, on: screen(for: source))
            phase = .capturing
            let outcome = try await CapturePipeline(backend: backend, store: store).screenshot(source)
            lastCapture = outcome
            lastError = nil
            let count = outcome.draft.bundle.media.count
            hud.flash("Saved \(outcome.media.filename)", subtitle: "\(count) capture\(count == 1 ? "" : "s") in this review")
        } catch is CancellationError {
            hud.hide()
        } catch let failure as CaptureFailure {
            hud.hide()
            if failure != .cancelled { report(failure) }
        } catch {
            hud.hide()
            report(.failed(String(describing: error)))
        }
    }

    private func countDown(_ request: CaptureRequest, on screen: NSScreen?) async throws {
        for seconds in request.countdown {
            phase = .countingDown(seconds)
            hud.showCountdown(seconds, on: screen)
            try await Task.sleep(for: .seconds(1))
        }
        hud.hide()
        if !request.countdown.isEmpty {
            // Let the HUD leave the screen before capturing (it is excluded anyway; this keeps
            // window captures of overlapping windows clean).
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    private func screen(for source: CaptureSource) -> NSScreen? {
        switch source {
        case let .display(id, _): DisplayDirectory.displays().first { $0.id == id }?.screen
        case .window: NSScreen.main
        }
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
