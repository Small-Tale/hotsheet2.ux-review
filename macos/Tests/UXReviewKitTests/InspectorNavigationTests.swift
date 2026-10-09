import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// The inspector's list → annotation editor stack follows the editor's selection
/// (`HS2-4R84WH`, docs/06 §6.5.1). Walks real editor sequences and checks the stack after each
/// step, including the stack's own changes (a row click pushes, Back pops) fed back through
/// `selection(afterNavigatingTo:current:)`.
struct InspectorNavigationTests {
    typealias Fixture = AnnotationEditorTests

    /// Applies what a change of the stack to `path` asks of the editor, as the inspector does.
    private func navigate(_ editor: inout AnnotationEditor, to path: [String]) {
        if let change = InspectorNavigation.selection(afterNavigatingTo: path, current: editor.selection) {
            editor.select(change)
        }
    }

    private func twoRects() -> AnnotationEditor {
        var editor = Fixture.editor(media: [Fixture.media("m1"), Fixture.media("m2")])
        Fixture.draw(&editor, .rect, [Fixture.p(100, 100), Fixture.p(300, 200)])
        Fixture.draw(&editor, .rect, [Fixture.p(400, 100), Fixture.p(600, 200)])
        editor.select(nil)
        return editor
    }

    @Test func pathFollowsTheSelection() {
        #expect(InspectorNavigation.path(selection: nil) == [])
        #expect(InspectorNavigation.path(selection: "a2") == ["a2"])
    }

    @Test func stackChangesMapToSelectionChanges() {
        // Unchanged: nothing to do (also the get/set echo SwiftUI sends after a push).
        #expect(InspectorNavigation.selection(afterNavigatingTo: [], current: nil) == nil)
        #expect(InspectorNavigation.selection(afterNavigatingTo: ["a1"], current: "a1") == nil)
        // Back from an editor: deselect.
        #expect(InspectorNavigation.selection(afterNavigatingTo: [], current: "a1") == .some(nil))
        // A row click (push), or a push over another editor: select it.
        #expect(InspectorNavigation.selection(afterNavigatingTo: ["a2"], current: nil) == .some("a2"))
        #expect(InspectorNavigation.selection(afterNavigatingTo: ["a1", "a2"], current: "a1") == .some("a2"))
    }

    /// Row click → canvas picks another → Back → canvas pick → Esc → Tab → delete → undo →
    /// another capture shown: the stack is the list exactly when nothing is selected.
    @Test func realSequencesKeepTheStackInStepWithTheCanvas() {
        var editor = twoRects()
        #expect(InspectorNavigation.path(selection: editor.selection) == [])

        navigate(&editor, to: ["a1"]) // list row
        #expect(editor.selection == "a1")
        #expect(InspectorNavigation.path(selection: editor.selection) == ["a1"])

        editor.select("a2") // canvas click on the other one: replaces, never stacks
        #expect(InspectorNavigation.path(selection: editor.selection) == ["a2"])

        navigate(&editor, to: []) // Back
        #expect(editor.selection == nil)
        navigate(&editor, to: []) // Back again (repeated): still the list, nothing changes
        #expect(editor.selection == nil)

        editor.select("a1") // canvas
        #expect(InspectorNavigation.path(selection: editor.selection) == ["a1"])
        editor.select(nil) // Esc / click on nothing
        #expect(InspectorNavigation.path(selection: editor.selection) == [])

        editor.selectNext() // Tab from the list
        #expect(InspectorNavigation.path(selection: editor.selection) == [editor.selection ?? "?"])
        #expect(editor.selection != nil)

        let deleted = editor.deleteSelection() // pops back to the list
        #expect(deleted)
        #expect(InspectorNavigation.path(selection: editor.selection) == [])
        editor.undo() // brings the annotation back selected: its editor shows again
        #expect(InspectorNavigation.path(selection: editor.selection).count == 1)

        editor.show(mediaId: "m2") // another capture: the list of that capture
        #expect(InspectorNavigation.path(selection: editor.selection) == [])
    }

    /// Empty, then refilled: the stack works again after the last annotation went away.
    @Test func emptyThenRefill() {
        var editor = Fixture.editor()
        #expect(InspectorNavigation.path(selection: editor.selection) == [])
        navigate(&editor, to: ["a9"]) // a stale row (already deleted): selects nothing
        #expect(editor.selection == nil)
        Fixture.draw(&editor, .rect, [Fixture.p(100, 100), Fixture.p(300, 200)])
        #expect(InspectorNavigation.path(selection: editor.selection) == ["a1"])
        navigate(&editor, to: [])
        #expect(editor.selection == nil)
    }
}
