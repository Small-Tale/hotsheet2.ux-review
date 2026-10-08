import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// Intent chip clicks (`HS2-JMPDDW`, docs/06 §6.5): a plain click selects one intent, ⌘ / ⇧ toggles.
struct IntentClickTests {
    static let shapes: [Shape] = [
        .rect(NormRect(x: 0, y: 0, width: 1, height: 1)),
        .strike(NormRect(x: 0, y: 0, width: 1, height: 1)),
        .arrow(points: [NormPoint(x: 0, y: 0), NormPoint(x: 1, y: 1)]),
        .insertion(NormPoint(x: 0, y: 0)),
        .freehand(points: [NormPoint(x: 0, y: 0), NormPoint(x: 1, y: 0), NormPoint(x: 1, y: 1)], closed: true),
    ]

    @Test func modifiersPickTheClick() {
        #expect(IntentToggle.Click(command: false, shift: false) == .single)
        #expect(IntentToggle.Click(command: true, shift: false) == .toggle)
        #expect(IntentToggle.Click(command: false, shift: true) == .toggle)
        #expect(IntentToggle.Click(command: true, shift: true) == .toggle)
    }

    @Test func aPlainClickSelectsJustThatIntent() {
        // Whatever was selected before, a plain click leaves only the clicked intent; the
        // shape's default is stored as [].
        let before: [[Intent]] = [[], [.bug], [.comment, .bug, .question], Intent.allCases]
        for shape in Self.shapes {
            for intents in before {
                for intent in Intent.allCases {
                    let after = IntentToggle.clicked(intents, intent, .single, shape: shape)
                    #expect(after == (intent == shape.defaultIntent ? [] : [intent]), "\(shape.kind) \(intents) \(intent)")
                    let effective = after.isEmpty ? [shape.defaultIntent] : after
                    #expect(effective == [intent])
                    // Clicking it again changes nothing.
                    #expect(IntentToggle.clicked(after, intent, .single, shape: shape) == after)
                }
            }
        }
    }

    @Test func aModifierClickTogglesOverTheEffectiveSet() {
        for shape in Self.shapes {
            for intents in [[], [Intent.bug], [.comment, .question]] {
                for intent in Intent.allCases {
                    #expect(
                        IntentToggle.clicked(intents, intent, .toggle, shape: shape)
                            == IntentToggle.toggled(intents, intent, shape: shape)
                    )
                }
            }
        }
    }

    @Test func editorClicksAreUndoableAndNoOpsLeaveNoHistory() {
        var editor = AnnotationEditorTests.editor()
        AnnotationEditorTests.draw(&editor, .rect, [AnnotationEditorTests.p(100, 100), AnnotationEditorTests.p(300, 200)])
        let depth = editor.undoStack.count
        func intents() -> [Intent] { editor.annotation("a1")?.intents ?? [.move] }
        func click(_ intent: Intent, _ click: IntentToggle.Click, id: String = "a1") -> Bool {
            editor.clickIntent(intent, click, for: id)
        }

        #expect(click(.bug, .single))
        #expect(intents() == [.bug])
        #expect(click(.question, .toggle)) // ⌘-click adds
        #expect(intents() == [.bug, .question])
        #expect(click(.change, .single)) // a plain click replaces the set
        #expect(intents() == [.change])
        #expect(!click(.change, .single)) // the only one again: nothing
        #expect(click(.change, .toggle)) // ⌘-click off the last one: back to the default
        #expect(intents() == [])
        #expect(!click(.comment, .single)) // the default, already the only one
        #expect(!click(.comment, .toggle)) // the default can't be removed
        #expect(!click(.bug, .single, id: "missing"))
        #expect(editor.undoStack.count == depth + 4)

        editor.undo()
        #expect(intents() == [.change])
        editor.undo()
        #expect(intents() == [.bug, .question])
        editor.redo()
        #expect(intents() == [.change])
        let toggled = editor.toggleIntent(.bug, for: "a1") // toggleIntent is the ⌘-click
        #expect(toggled)
        #expect(intents() == [.bug, .change])
    }

    @Test func scriptIntentStepsTakeAnOptionalModifier() throws {
        func step(_ json: String) throws -> EditorScript.Step {
            try JSONDecoder().decode(EditorScript.Step.self, from: Data(json.utf8))
        }
        #expect(try step(#"{"op": "intent", "intent": "bug"}"#) == .intent(.bug, .single))
        #expect(try step(#"{"op": "intent", "intent": "bug", "modifier": "command"}"#) == .intent(.bug, .toggle))
        #expect(try step(#"{"op": "intent", "intent": "bug", "modifier": "shift"}"#) == .intent(.bug, .toggle))
        #expect(throws: DecodingError.self) { try step(#"{"op": "intent", "intent": "bug", "modifier": "option"}"#) }
    }
}
