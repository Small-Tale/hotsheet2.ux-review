import AppKit
import SwiftUI
import UXReviewKit

/// Typing into the note text view of a real editor (docs/06 §6.5).
extension EditorPreviews {
    /// Types three characters into the middle of annotation #1's note through the real note text
    /// view, one at a time with the run loop turning in between, and records the text and the
    /// insertion point after each (`editor-note-typing.json`, `HS2-XCJPTX`): the insertion point
    /// must stay right after what was typed, not jump to the end.
    static func typeInTheMiddleOfANote(to directory: URL, store: ReviewDraftStore, draft: ReviewDraft) throws -> URL {
        let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
        annotations.forEach { apply($0, to: model) }
        apply(.select("#1"), to: model)
        let size = CGSize(width: 1240, height: 800)
        let host = NSHostingView(rootView: EditorView(model: model).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let text = host.firstDescendant(NSTextView.self) else { throw CaptureFailure.failed("no note text view") }
        window.makeFirstResponder(text)
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        // After "Field label" (11 characters).
        text.setSelectedRange(NSRange(location: 11, length: 0))
        settle()
        var steps: [[String: Any]] = []
        for character in ["X", "Y", "Z"] {
            text.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
            settle()
            steps.append([
                "typed": character,
                "text": text.string,
                "note": model.editor.annotations(on: model.editor.currentMediaId ?? "").first?.note ?? "",
                "insertionPoint": text.selectedRange().location,
            ])
        }
        let url = directory.appendingPathComponent("editor-note-typing.json")
        try JSONSerialization.data(withJSONObject: steps, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        return url
    }
}
