import AppKit
import SwiftUI
import UXReviewKit

/// One "Submit Review" window per draft. It saves the title and summary when it closes.
/// Spec: docs/07-review-session.md §7.1.
@MainActor
final class ReviewSessionWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [URL: ReviewSessionWindowController] = [:]

    let model: ReviewSessionModel

    /// Opens (or brings forward) the session window for the current draft review.
    static func showCurrent(store: ReviewDraftStore) {
        do {
            guard let draft = try store.current() else {
                let alert = NSAlert()
                alert.messageText = "Nothing to submit yet"
                alert.informativeText = "Capture a screenshot or record a video first. Each capture is added to the current review."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                return
            }
            show(draft: draft, store: store)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't open the current review"
            alert.informativeText = ReviewSubmitter.describe(error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    static func show(draft: ReviewDraft, store: ReviewDraftStore) {
        let key = draft.directory.standardizedFileURL
        if let existing = open[key] {
            existing.model.reload()
            existing.model.refreshTarget()
            existing.present()
            return
        }
        let model = ReviewSessionModel(draft: draft, store: store, target: AppSettings.currentStatus())
        model.closeEditor = { EditorWindowController.close(directory: $0) }
        let controller = ReviewSessionWindowController(model: model)
        open[key] = controller
        controller.present()
    }

    /// Closes the session window on `directory`, if one is open (it saves the title and
    /// summary first). Discarding the draft does this (docs/07 §7.9).
    static func close(directory: URL) {
        open[directory.standardizedFileURL]?.window?.close()
    }

    init(model: ReviewSessionModel) {
        self.model = model
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Submit Review"
        window.contentMinSize = CGSize(width: 520, height: 480)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("UXReviewSession")
        super.init(window: window)
        let store = model.store
        window.contentView = NSHostingView(rootView: ReviewSessionView(
            model: model,
            annotate: { [weak model] mediaId in
                guard let model else { return }
                model.saveFields()
                do {
                    try EditorWindowController.show(directory: model.directory, store: store, mediaId: mediaId)
                } catch {
                    NSSound.beep()
                }
            },
            done: { [weak window] in window?.close() },
            discard: { [weak model, weak window] in
                guard let model else { return }
                model.saveFields()
                DraftDiscarding.confirm(model.directory, store: store, window: window)
            }
        ))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    private func present() {
        EditMenu.install()
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        model.saveFields()
        Self.open = Self.open.filter { $0.value !== self }
    }
}
