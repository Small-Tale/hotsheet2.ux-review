import AppKit
import Combine
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
        let model = ReviewSessionModel(draft: draft, store: store, target: AppSettings.status(forDraft: draft.directory))
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

    /// True while a session window shows the review in `directory`.
    static func isOpen(directory: URL) -> Bool { open[directory.standardizedFileURL] != nil }

    init(model: ReviewSessionModel) {
        self.model = model
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Submit Review"
        window.contentMinSize = ReviewSessionView.minimumSize
        window.isReleasedWhenClosed = false
        WindowSizing.restoreFrame(window, name: "UXReviewSession")
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
            done: { [weak window] in window?.close() }
        ))
        window.delegate = self
        phaseChanges = model.$session
            .map { if case .submitted = $0.phase { true } else { false } }
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak window, weak model] _ in
                MainActor.assumeIsolated {
                    guard let window, let model, case let .submitted(review) = model.session.phase else { return }
                    // Usually a transient HUD confirms it and the window closes (HS2-ZYV3SC); a
                    // filing that needs the reviewer keeps the result page.
                    if review.needsResultWindow {
                        Self.fitToSubmitted(window)
                    } else {
                        FiledHUD.show(review, model: model, centeredOn: window.frame)
                        window.close()
                    }
                }
            }
        abandonedChanges = model.$abandonedTicket
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak window, weak model] _ in
                MainActor.assumeIsolated {
                    guard let window, let model, case .submitted = model.session.phase else { return }
                    Self.fitToSubmitted(window)
                }
            }
    }

    private var phaseChanges: AnyCancellable?
    /// Refits a filed review's window when the leftover-ticket row under the message changes.
    private var abandonedChanges: AnyCancellable?

    /// Shrinks the window around the success message once the review is filed (`HS2-J2BE94`): the
    /// form's size, possibly very tall, would leave the message floating in empty space. The top
    /// edge stays put and the window stops resizing. Autosaving stops first, so the next Submit
    /// Review window still opens at the form's saved size.
    static func fitToSubmitted(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        window.setFrameAutosaveName("")
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let size = CGSize(width: max(ceil(fitting.width), ReviewSessionView.minimumSize.width), height: ceil(fitting.height))
        window.contentMinSize = size
        window.contentMaxSize = size
        window.styleMask.remove(.resizable)
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    private func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        DockPresence.present(window)
    }

    // MARK: File menu, for this window's draft

    /// Add Media… (⌘O): adds images or movies to *this* draft, all or nothing (docs/04 §4.12.2).
    @objc func addMedia(_: Any?) {
        guard let window else { return }
        let panel = MediaChooser.panel()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            MainActor.assumeIsolated { self?.add(panel.urls) }
        }
    }

    private func add(_ urls: [URL]) {
        let store = model.store
        let directory = model.directory
        Task {
            do {
                let (draft, _) = try await MediaOpenRouting.open(urls, into: store, draft: directory)
                NotificationCenter.default.post(name: .reviewDraftChanged, object: draft.directory)
            } catch {
                guard let window else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn't add that media"
                let reason = (error as? MediaImportError)?.description ?? String(describing: error)
                alert.informativeText = "\(reason) Nothing was added to the review."
                alert.beginSheetModal(for: window) { _ in }
            }
        }
    }

    /// Discard Review… is off once the review is filed (or while it is being filed).
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(discardReview(_:)) ? model.session.isEditable : true
    }

    /// File › Discard Review… (`HS2-7B92Y3`): asks, then moves this review to the Trash.
    @objc func discardReview(_: Any?) {
        guard model.session.isEditable else { return }
        model.saveFields()
        DraftDiscarding.confirm(model.directory, store: model.store, window: window)
    }

    @objc func revealReview(_: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([model.directory])
    }

    func windowWillClose(_: Notification) {
        model.saveFields()
        Self.open = Self.open.filter { $0.value !== self }
    }
}
