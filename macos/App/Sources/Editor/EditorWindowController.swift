import AppKit
import SwiftUI
import UXReviewKit

/// One editor window per draft review. It saves when it closes, and it supplies undo/redo for the
/// Edit menu when the canvas (not a text field) has focus. Spec: docs/06-annotation-editor.md §6.1.
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
        let session = try EditorSession(store: store, directory: directory, mediaId: mediaId)
        let controller = EditorWindowController(model: EditorModel(session: session))
        open[key] = controller
        controller.present()
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
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    private func present() {
        EditMenu.install()
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let canvas = window?.contentView?.firstDescendant(AnnotationCanvasView.self) {
            window?.makeFirstResponder(canvas)
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

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): model.editor.canUndo
        case #selector(redo(_:)): model.editor.canRedo
        case #selector(duplicate(_:)): model.editor.selection != nil
        default: true
        }
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

/// UX Review is a menu bar app with no visible main menu, but key equivalents (⌘Z, ⌘C, ⌘V, …)
/// still route through `NSApp.mainMenu`, so the editor installs a minimal one.
enum EditMenu {
    @MainActor static func install() {
        guard NSApp.mainMenu?.item(withTitle: "Edit") == nil else { return }
        let main = NSApp.mainMenu ?? NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(AnnotationCanvasView.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: #selector(AnnotationCanvasView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Duplicate", action: #selector(AnnotationCanvasView.duplicate(_:)), keyEquivalent: "d")
        edit.addItem(withTitle: "Save", action: #selector(AnnotationCanvasView.saveDocument(_:)), keyEquivalent: "s")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        main.addItem(item)
        NSApp.mainMenu = main
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
