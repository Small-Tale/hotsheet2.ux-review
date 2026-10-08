import AppKit
import SwiftUI
import UXReviewKit

/// One UX Review window per draft review: the annotation editor. It saves when it closes, and it
/// supplies undo/redo for the Edit menu when the canvas (not a text field) has focus, and the
/// File menu's Add Media…, Submit Review…, and Show Review in Finder for *its* draft.
/// Spec: docs/06-annotation-editor.md §6.1.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [URL: EditorWindowController] = [:]

    let model: EditorModel

    /// Opens (or brings forward) the editor for the draft in `directory`, showing `mediaId` when given.
    static func show(directory: URL, store: ReviewDraftStore, mediaId: String? = nil) throws {
        let key = directory.standardizedFileURL
        if let existing = open[key] {
            if let mediaId { existing.model.show(mediaId: mediaId) }
            existing.present()
            return
        }
        let session = try EditorSession(store: store, directory: directory, mediaId: mediaId, frameRateLoading: .inBackground)
        let controller = EditorWindowController(model: EditorModel(session: session))
        open[key] = controller
        controller.present()
    }

    /// Brings every open editor window forward; false when none is open.
    @discardableResult
    static func bringAllForward() -> Bool {
        let controllers = open.values.sorted { ($0.window?.orderedIndex ?? 0) > ($1.window?.orderedIndex ?? 0) }
        for controller in controllers {
            controller.present()
        }
        return !controllers.isEmpty
    }

    /// Saves and closes the editor on `directory`, if one is open. The review session does this
    /// before it removes a capture or submits (docs/07 §7.2), so the editor never writes stale
    /// annotations back into a changed or deleted draft.
    static func close(directory: URL) {
        open[directory.standardizedFileURL]?.window?.close()
    }

    init(model: EditorModel) {
        self.model = model
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1240, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(model.editor.bundle.title) — Annotate"
        let content = EditorHostingView(rootView: EditorView(model: model))
        window.contentView = content
        window.contentMinSize = CGSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("UXReviewEditor")
        super.init(window: window)
        window.delegate = self
        content.onDropFiles = { [weak self] urls in self?.addDroppedFiles(urls) }
        model.submitReview = { [weak self] in self?.submitReview(nil) }
        model.addMedia = { [weak self] in self?.addMedia(nil) }
        model.confirmRemoval = { [weak self] items in self?.confirmRemoval(items) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    private func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        DockPresence.track(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let canvas = window.contentView?.firstDescendant(AnnotationCanvasView.self) {
            window.makeFirstResponder(canvas)
        }
    }

    /// Files dragged onto the window go into *this* draft (not the current one), all or nothing,
    /// and the editor switches to the first of them (docs/04 §4.12.2).
    func addDroppedFiles(_ urls: [URL]) {
        let session = model.session
        Task {
            do {
                let (draft, media) = try await MediaOpenRouting.open(urls, into: session.store, draft: session.directory)
                NotificationCenter.default.post(name: .reviewDraftChanged, object: draft.directory)
                if let first = media.first { model.show(mediaId: first.id) }
            } catch {
                showDropError(error)
            }
        }
    }

    private func showDropError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't add that media"
        let reason = (error as? MediaImportError)?.description ?? String(describing: error)
        alert.informativeText = "\(reason) Nothing was added to the review. Drop images or movies."
        alert.beginSheetModal(for: window)
    }

    func windowWillClose(_: Notification) {
        model.pause()
        model.save()
        Self.open = Self.open.filter { $0.value !== self }
    }

    // MARK: Edit menu actions (reached through the responder chain)

    @objc func undo(_: Any?) { model.mutate { $0.undo() } }
    @objc func redo(_: Any?) { model.mutate { $0.redo() } }
    @objc func duplicate(_: Any?) { model.mutate { _ = $0.duplicateSelection() } }
    @objc func saveDocument(_: Any?) { model.save() }

    /// Add Media… (tool bar, ⌘O): choose images or movies to add to *this* draft, like a drop.
    @objc func addMedia(_: Any?) {
        guard let window else { return }
        let panel = MediaChooser.panel()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            MainActor.assumeIsolated { self?.addDroppedFiles(panel.urls) }
        }
    }

    /// Edit › Remove Capture from Review…: the selected captures, after asking (docs/06 §6.7.1).
    @objc func removeCapture(_: Any?) {
        confirmRemoval(selectedItems)
    }

    /// Edit › Remove Captures Now (⌘⌫): the selected captures, without asking (docs/06 §6.7.2).
    @objc func removeSelectedCaptures(_: Any?) {
        model.removeCaptures(model.editor.mediaToRemove())
    }

    private var selectedItems: [MediaItem] {
        model.editor.mediaToRemove().compactMap(model.editor.media)
    }

    /// Asks, as a sheet, before deleting captures' files and annotations; it can't be undone.
    func confirmRemoval(_ items: [MediaItem]) {
        guard let window, !items.isEmpty else { return }
        let prompt = CaptureRemovalPrompt(
            filenames: items.map(\.filename),
            annotations: items.map { model.editor.annotations(on: $0.id).count }.reduce(0, +)
        )
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.message
        alert.informativeText = prompt.detail
        alert.addButton(withTitle: prompt.button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let ids = items.map(\.id)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.model.removeCaptures(ids) }
        }
    }

    @objc func revealReview(_: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([model.session.directory])
    }

    /// Submit Review… (tool bar, ⌘↩): saves, then opens the session window on *this* draft,
    /// which may not be the current one (docs/07 §7.1).
    @objc func submitReview(_: Any?) {
        model.pause()
        model.save()
        let session = model.session
        do {
            try ReviewSessionWindowController.show(draft: session.store.load(session.directory), store: session.store)
        } catch {
            guard let window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't open the review"
            alert.informativeText = ReviewSubmitter.describe(error)
            alert.beginSheetModal(for: window)
        }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): model.editor.canUndo
        case #selector(redo(_:)): model.editor.canRedo
        case #selector(duplicate(_:)): model.editor.selection != nil
        case #selector(removeCapture(_:)):
            retitle(item, "\(CaptureRemovalPrompt.title(count: max(selectedItems.count, 1))) from Review…")
        case #selector(removeSelectedCaptures(_:)):
            // Off while text is being edited, so ⌘⌫ deletes text in the note field instead.
            retitle(item, "\(CaptureRemovalPrompt.title(count: max(selectedItems.count, 1))) Now") && !(window?.firstResponder is NSText)
        default: true
        }
    }

    /// Names the selection's size in a remove item's title; true when there is something to remove.
    private func retitle(_ item: NSMenuItem, _ title: String) -> Bool {
        item.title = title
        return !selectedItems.isEmpty
    }
}

/// The editor window's content: the SwiftUI editor plus a drop target for image and movie
/// files from Finder. Other drags go to SwiftUI as usual. Spec: docs/04-capture.md §4.12.2.
final class EditorHostingView: NSHostingView<EditorView> {
    var onDropFiles: (([URL]) -> Void)?

    required init(rootView: EditorView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Every file drag is accepted so a wrong type gets an explanation on drop, not just a bounce.
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onDropFiles?(urls)
        return true
    }
}

/// The open panel for Add Media… and Open Media (docs/04 §4.12).
enum MediaChooser {
    @MainActor static func panel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Add Media"
        panel.message = "Choose screenshots, images, or movies to add to the review."
        panel.prompt = "Add"
        panel.allowedContentTypes = MediaImporter.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        return panel
    }
}

extension NSView {
    func firstDescendant<T: NSView>(_: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(T.self) { return match }
        }
        return nil
    }
}
