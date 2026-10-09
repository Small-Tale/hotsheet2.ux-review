import AppKit
import SwiftUI
import UXReviewKit

/// The editor window's native toolbar (docs/06 §6.1, `HS2-WHP4V1`).
extension EditorPreviews {
    /// Typing in a note (`editor-note-typing.json`) and the window toolbar.
    static func renderWindowInteractions(to directory: URL, store: ReviewDraftStore, draft: ReviewDraft) throws -> [URL] {
        try [typeInTheMiddleOfANote(to: directory, store: store, draft: draft)] + renderToolbar(to: directory, store: store, draft: draft)
    }

    /// A titled window with the real `EditorToolbar` over the editor, as the editor window builds
    /// it: the toolbar's items after opening (Select tool, nothing to restore), after the C key's
    /// tool change and a crop (Crop selected, Restore Original shown), written to
    /// `editor-toolbar.json` with the window's title, subtitle and proxy icon; the window frame,
    /// title bar and toolbar included, drawn as `editor-window.png`.
    static func renderToolbar(to directory: URL, store: ReviewDraftStore, draft: ReviewDraft) throws -> [URL] {
        let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
        annotations.forEach { apply($0, to: model) }
        apply(.select("#1"), to: model)
        let size = CGSize(width: 1240, height: 800)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        EditorWindowController.title(window, for: model)
        window.contentView = EditorHostingView(rootView: EditorView(model: model))
        var submitted = 0
        let toolbar = EditorToolbar(model: model) { submitted += 1 }
        toolbar.install(on: window)
        // The toolbar follows the model on later run loop turns. Under load one 50 ms turn wasn't
        // enough (HS2-5D947C), so wait, up to 2 s, until `done` says the expected state arrived.
        func settle(until done: () -> Bool = { true }) {
            let deadline = Date().addingTimeInterval(2)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                window.contentView?.layoutSubtreeIfNeeded()
            } while !done() && Date() < deadline
        }
        settle()
        let opened = toolbar.describe()
        // The rendered window: the theme frame holds the title bar and toolbar.
        var written: [URL] = []
        if let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            if let image = rep.cgImage {
                let url = directory.appendingPathComponent("editor-window.png")
                try ImageFiles.writePNG(image, to: url)
                written.append(url)
            }
        }
        // C (keyboard) chooses Crop; cropping makes Restore Original appear.
        model.mutate { $0.setTool(.crop) }
        apply(.crop(CGRect(x: 220, y: 90, width: 1180, height: 560)), to: model)
        settle { toolbar.describe()["restoreHidden"] as? Bool == false }
        let cropped = toolbar.describe()
        if let submit = window.toolbar?.items.first(where: { $0.itemIdentifier == EditorToolbar.submitReview }),
           let action = submit.action {
            NSApp.sendAction(action, to: submit.target, from: submit)
        }
        model.cancelAutosave()
        let url = directory.appendingPathComponent("editor-toolbar.json")
        try JSONSerialization.data(
            withJSONObject: [
                "opened": opened, "cropped": cropped, "submitted": submitted,
                "toolbarStyle": window.toolbarStyle == .unified ? "unified" : "other",
                "titleVisible": window.titleVisibility == .visible,
                "title": window.title, "subtitle": window.subtitle, "proxyIcon": window.representedURL != nil,
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: url)
        written.append(url)
        return written
    }
}
