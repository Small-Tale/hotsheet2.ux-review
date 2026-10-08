import AppKit
import UXReviewKit

/// The app: a menu bar icon (`StatusItemController`) that captures, plus UX Review windows
/// (editor, Submit Review, Draft Reviews, Settings). While one of those is open the app shows a
/// Dock icon and its menu bar (`DockPresence`, `MainMenu`). Spec: docs/05-start-and-settings.md §5.1.
///
/// It is also the end of the responder chain: File menu actions that no window answers act on
/// the current draft here. And it receives images and movies opened from Finder ("Open With",
/// or dropped on the Dock icon; the document types are declared in project.yml). URLs that
/// arrive within `batchDelay` of each other import as one all-or-nothing batch into the current
/// draft (docs/04-capture.md §4.12.1).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static let batchDelay: Duration = .milliseconds(300)

    private(set) var capture: CaptureCoordinator?
    private(set) var settings: SettingsModel?
    private var statusItem: StatusItemController?
    private var batch = OpenBatch()
    private var waiting = false

    func applicationDidFinishLaunching(_: Notification) {
        let capture = CaptureCoordinator()
        let settings = SettingsModel()
        // A global hotkey starts its capture, or cancels a countdown / stops a recording.
        settings.hotkeys.onPress = { [weak capture, weak settings] slot in
            guard let capture, let settings else { return }
            capture.handleHotkey(slot, settings: settings.settings)
        }
        capture.stopHint = { [weak settings] in
            let hotkey = settings?.activeHotkey(.record) ?? settings?.activeHotkey(.capture)
            return hotkey.map { "Stop from the menu bar or press \($0.display)" } ?? "Stop from the menu bar"
        }
        capture.narrationDefault = { [weak settings] in settings?.settings.narration ?? false }
        capture.recordingPointer = { [weak settings] in settings?.settings.recordingPointer ?? RecordingPointer() }
        self.capture = capture
        self.settings = settings
        statusItem = StatusItemController(
            phase: capture.$phase,
            state: { [weak self] in self?.menuState() ?? MenuState() },
            perform: { [weak self] in self?.perform($0) }
        )
        MainMenu.install(
            captureEntries: { [weak self] in AppMenus.captureMenu(self?.menuState() ?? MenuState()) },
            perform: { [weak self] in self?.perform($0) }
        )
        flushIfReady()
    }

    func menuState() -> MenuState {
        guard let capture, let settings else { return MenuState() }
        var hotkeys: [HotkeySlot: Hotkey] = [:]
        for slot in HotkeySlot.allCases {
            hotkeys[slot] = settings.activeHotkey(slot)
        }
        return MenuState(
            phase: capture.phase,
            settings: settings.settings,
            narratesNextRecording: capture.narratesNextRecording,
            recordingNarration: capture.recordingNarration,
            hotkeys: hotkeys,
            version: AppSettings.version
        )
    }

    func perform(_ command: MenuCommand) {
        guard let capture, let settings else { return }
        switch command {
        case let .capture(request): capture.start(request)
        // The same setting as Settings › Default capture › Capture (an open Settings window follows).
        case let .setCaptureTarget(target): settings.update { $0.defaultRequest.target = target }
        case .cancelCapture: capture.cancel()
        case .stopRecording: capture.stopRecording()
        case .toggleNarration:
            let next = !capture.narratesNextRecording
            capture.narrationChoice = next == settings.settings.narration ? nil : next
        case .openSettings: SettingsWindowController.show(model: settings)
        case .openUXReview: capture.openUXReview()
        case .quit: NSApp.terminate(nil)
        }
    }

    /// Clicking the Dock icon with no window showing opens UX Review on the current review.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { capture?.openUXReview() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    // MARK: Opening files from Finder

    func application(_: NSApplication, open urls: [URL]) {
        guard batch.add(urls) else { return }
        waiting = true
        Task {
            try? await Task.sleep(for: Self.batchDelay)
            waiting = false
            flushIfReady()
        }
    }

    /// URLs that arrive before launch finishes wait in the batch.
    private func flushIfReady() {
        guard !waiting, let capture, !batch.pending.isEmpty else { return }
        capture.openMedia(batch.flush())
    }

    /// The standard About panel under the full product name (docs/05 §5.1.1).
    @objc func showAbout(_: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: ProductName.full])
        NSApp.activate()
    }

    // MARK: File menu, when no window answers (the current draft)

    @objc func openSettings(_: Any?) { perform(.openSettings) }
    @objc func newReview(_: Any?) { capture?.newReview() }
    @objc func addMedia(_: Any?) { capture?.openMediaForAnnotation() }
    @objc func showDraftReviews(_: Any?) {
        if let store = capture?.store { DraftsWindowController.show(store: store) }
    }

    @objc func submitReview(_: Any?) {
        if let store = capture?.store { ReviewSessionWindowController.showCurrent(store: store) }
    }

    @objc func revealReview(_: Any?) { capture?.revealCurrentReview() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(submitReview(_:)):
            // Let ⌘↩ reach the Submit Review window's own Submit button.
            !(NSApp.keyWindow?.windowController is ReviewSessionWindowController)
        case #selector(revealReview(_:)):
            capture?.hasCurrentReview ?? false
        default:
            true
        }
    }
}
