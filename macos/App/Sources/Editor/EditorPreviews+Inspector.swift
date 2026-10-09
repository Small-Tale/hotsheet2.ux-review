import AppKit
import SwiftUI
import UXReviewKit

/// The inspector's navigation stack (`HS2-4R84WH`, docs/06 §6.5.1) driven by real mouse and key
/// events in an off-screen key window: a click on a list row pushes that annotation's page, a click
/// on Back pops to the list and deselects, ⌘[ does the same, and a note-focus request made just
/// before the page is pushed (a double-click on the canvas) focuses the note once it shows.
/// Writes `editor-inspector-navigation.json` and renders the list and the pushed page.
extension EditorPreviews {
    static func renderInspectorNavigation(to directory: URL, store: ReviewDraftStore, draft: ReviewDraft) throws -> [URL] {
        let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
        offerWindowButtons(model)
        annotations.forEach { apply($0, to: model) }
        let ids = model.editor.annotations(on: model.editor.currentMediaId ?? "").map(\.id)
        let clicker = ClickableEditor(EditorView(model: model, stripWidthOverride: MediaStripWidth.standard))
        defer { clicker.close() }
        var written = [try clicker.snapshot(to: directory.appendingPathComponent("editor-inspector-list.png"))]
        let inspectorX = clicker.size.width - 150

        // The first row: clicks down the inspector until one selects something.
        var row: [String: Any] = [:]
        for y in stride(from: 10, through: 200, by: 4) where model.editor.selection == nil {
            clicker.click(CGPoint(x: inspectorX, y: CGFloat(y)))
            if let selected = model.editor.selection { row = ["y": y, "selected": ids.firstIndex(of: selected).map { $0 + 1 } ?? 0] }
        }
        written.append(try clicker.snapshot(to: directory.appendingPathComponent("editor-inspector-pushed.png")))

        // Back: clicks across the page's top bar until the selection clears.
        var back: [String: Any] = [:]
        for y in stride(from: 4, through: 40, by: 4) where model.editor.selection != nil {
            clicker.click(CGPoint(x: clicker.size.width - 270, y: CGFloat(y)))
            if model.editor.selection == nil { back = ["y": y] }
        }

        // ⌘[ from a page selected on the canvas.
        model.mutate { $0.select(ids[1]) }
        clicker.settle()
        let handled = clicker.pressKeyEquivalent("[", keyCode: 33, modifiers: .command)
        let afterShortcut = model.editor.selection

        // A double-click on the canvas: select, then ask for the note before the page is pushed.
        model.mutate { $0.select(ids[2]) }
        model.focusNoteRequest += 1
        for _ in 0 ..< 10 where !clicker.textHasFocus {
            clicker.settle()
        }
        let result: [String: Any] = [
            "annotations": ids.count, "rowClick": row, "backClick": back,
            "commandBracket": ["handled": handled, "selection": afterShortcut ?? "none"],
            "noteFocusedAfterPush": clicker.textHasFocus,
        ]
        model.cancelAutosave()
        let url = directory.appendingPathComponent("editor-inspector-navigation.json")
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        written.append(url)
        return written
    }
}
