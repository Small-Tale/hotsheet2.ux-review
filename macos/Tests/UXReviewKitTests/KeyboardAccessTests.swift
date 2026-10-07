import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// Keyboard-only drawing (Return inserts a default shape) and the VoiceOver labels of canvas
/// annotations (docs/06 §6.4). Media is 1000 × 500 px, so the default side is 100 px.
struct KeyboardAccessTests {
    typealias Fixture = AnnotationEditorTests

    @Test func insertsEachToolsDefaultShapeAtTheCenter() throws {
        let cases: [(EditorTool, Shape)] = [
            (.rect, .rect(NormRect(x: 4500, y: 4000, width: 1000, height: 2000))),
            (.strike, .strike(NormRect(x: 4500, y: 4000, width: 1000, height: 2000))),
            (.arrow, .arrow(points: [NormPoint(x: 4500, y: 6000), NormPoint(x: 5500, y: 4000)])),
            (.insertion, .insertion(NormPoint(x: 5000, y: 5000))),
        ]
        for (tool, expected) in cases {
            var editor = Fixture.editor()
            editor.setTool(tool)
            let inserted1 = editor.insertDefaultShape()
            #expect(inserted1)
            #expect(editor.bundle.annotations.map(\.shape) == [expected], "\(tool)")
            #expect(editor.selection == "a1")
            #expect(editor.tool == .select) // like drawing: back to Select, shape selected
        }
        var editor = Fixture.editor()
        editor.setTool(.freehand)
        let inserted2 = editor.insertDefaultShape()
        #expect(inserted2)
        guard case let .freehand(points, closed) = editor.bundle.annotations[0].shape else { Issue.record("not freehand"); return }
        #expect(closed && points.count == 12)
        #expect(editor.bundle.annotations[0].shape.bounds == NormRect(x: 4500, y: 4000, width: 1000, height: 2000))
    }

    /// Return, then arrows, then undo: one undo step for the insert, one coalesced run of nudges.
    @Test func insertThenNudgeThenUndo() {
        var editor = Fixture.editor()
        editor.setTool(.rect)
        editor.insertDefaultShape()
        for _ in 0 ..< 5 {
            editor.nudgeSelection(dx: 10, dy: 0)
        }
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 5000, y: 4000, width: 1000, height: 2000)))
        editor.undo() // the nudges
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 4500, y: 4000, width: 1000, height: 2000)))
        editor.undo() // the insert
        #expect(editor.bundle.annotations.isEmpty)
        #expect(!editor.canUndo)
        editor.redo()
        #expect(editor.bundle.annotations.count == 1)
    }

    @Test func staysInsideTheMediaNearAnEdge() {
        var editor = Fixture.editor()
        editor.setTool(.rect)
        editor.insertDefaultShape(at: CGPoint(x: 990, y: -40))
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 9000, y: 0, width: 1000, height: 2000)))
        editor.setTool(.insertion)
        editor.insertDefaultShape(at: CGPoint(x: 10, y: 250))
        #expect(editor.bundle.annotations[1].shape == .insertion(NormPoint(x: 500, y: 5000))) // kept a half-side in
    }

    @Test func refusesWithoutADrawingTool() {
        var editor = Fixture.editor()
        let inserted3 = editor.insertDefaultShape()
        #expect(!inserted3) // Select
        editor.setTool(.crop)
        let inserted4 = editor.insertDefaultShape()
        #expect(!inserted4)
        #expect(editor.message?.contains("Drag to crop") == true)
        editor.setTool(.rect)
        editor.beginGesture(at: CGPoint(x: 10, y: 10)) // mid-drag
        let inserted5 = editor.insertDefaultShape()
        #expect(!inserted5)
        editor.cancelGesture()
        var empty = Fixture.editor(media: [])
        empty.setTool(.rect)
        let inserted6 = empty.insertDefaultShape()
        #expect(!inserted6)
        #expect(editor.bundle.annotations.isEmpty && !editor.canUndo)
    }

    @Test func accessibilityLabelsReadNumberShapeIntentsAndNote() {
        var editor = Fixture.editor(media: [Fixture.media("m1"), Fixture.media("m2")])
        Fixture.draw(&editor, .rect, [Fixture.p(10, 10), Fixture.p(100, 60)])
        editor.setNote("Field label is **clipped**.", for: "a1")
        editor.toggleIntent(.bug, for: "a1")
        editor.show(mediaId: "m2")
        Fixture.draw(&editor, .strike, [Fixture.p(10, 10), Fixture.p(100, 60)])
        #expect(editor.accessibilityLabel(for: "a1") == "Annotation 1: Rectangle, comment, bug. Field label is **clipped**.")
        #expect(editor.accessibilityLabel(for: "a2") == "Annotation 2: Strike, remove. No note.")
        #expect(editor.accessibilityLabel(for: "a9") == nil)
    }

    @Test func scriptsInsertWithTheKeyboardPath() throws {
        let script = try JSONDecoder().decode(EditorScript.self, from: Data(#"""
        {"steps": [{"op": "tool", "tool": "arrow"}, {"op": "insert"},
                   {"op": "tool", "tool": "rect"}, {"op": "insert", "point": [100, 100]}]}
        """#.utf8))
        #expect(script.steps[1] == .insert(nil))
        #expect(script.steps[3] == .insert(CGPoint(x: 100, y: 100)))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditorScript.self, from: Data(#"{"steps": [{"op": "insert", "point": [1]}]}"#.utf8))
        }
    }
}
