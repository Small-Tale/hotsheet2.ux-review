import AppKit
import Combine
import SwiftUI
import UXReviewKit

/// The Draft Reviews window's state: every draft on disk, re-read when a draft changes and
/// whenever the window comes forward. Spec: docs/07-review-session.md §7.9.
@MainActor
final class DraftsModel: ObservableObject {
    @Published private(set) var drafts: [DraftSummary] = []
    /// The drafts folder couldn't be read.
    @Published private(set) var problem: String?

    let store: ReviewDraftStore
    private var subscription: AnyCancellable?

    init(store: ReviewDraftStore) {
        self.store = store
        reload()
        subscription = NotificationCenter.default.publisher(for: .reviewDraftChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
    }

    func reload() {
        do {
            drafts = try store.listDrafts()
            problem = nil
        } catch {
            problem = "Couldn't read the drafts folder: \(ReviewSubmitter.describe(error))"
        }
    }
}

/// One Draft Reviews window (menu: Draft Reviews…): open, annotate, reveal, or discard any
/// draft, not only the current one. Spec: docs/07-review-session.md §7.9.
@MainActor
final class DraftsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: DraftsWindowController?

    let model: DraftsModel

    static func show(store: ReviewDraftStore) {
        let controller = shared ?? DraftsWindowController(model: DraftsModel(store: store))
        shared = controller
        controller.model.reload()
        guard let window = controller.window else { return }
        if !window.isVisible { window.center() }
        DockPresence.track(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    init(model: DraftsModel) {
        self.model = model
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Draft Reviews"
        window.contentMinSize = DraftsView.minimumSize
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("UXReviewDrafts")
        super.init(window: window)
        let store = model.store
        window.contentView = NSHostingView(rootView: DraftsView(model: model, actions: DraftsView.Actions(
            openSession: { draft in
                do {
                    try ReviewSessionWindowController.show(draft: store.load(draft.directory), store: store)
                } catch {
                    Self.report("Couldn't open the review", error)
                }
            },
            annotate: { draft in
                do {
                    try EditorWindowController.show(directory: draft.directory, store: store)
                } catch {
                    Self.report("Couldn't open the editor", error)
                }
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0.directory]) },
            discard: { [weak window] draft in DraftDiscarding.confirm(draft.directory, store: store, window: window) },
            showFolder: { NSWorkspace.shared.activateFileViewerSelecting([store.root]) }
        )))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func windowDidBecomeKey(_: Notification) {
        model.reload()
    }

    private static func report(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = ReviewSubmitter.describe(error)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
