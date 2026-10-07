import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// The annotation editor's state machine. States: idle (no selection / a selection), gesture
/// in progress (drawing, moving, resizing, cropping); history: undo/redo stacks with
/// coalescing. Each test walks a realistic or adversarial sequence across those boundaries.
/// Media is 1000 × 500 px, so 1 px = 10 units across and 20 units down.
struct AnnotationEditorTests {
    static func media(_ id: String = "m1", filename: String? = nil, kind: MediaKind = .image) -> MediaItem {
        MediaItem(
            id: id, filename: filename ?? "\(id).png", kind: kind, pixelWidth: 1000, pixelHeight: 500,
            durationMs: kind == .video ? 4000 : nil, capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func editor(media: [MediaItem] = [media()], annotations: [Annotation] = []) -> AnnotationEditor {
        AnnotationEditor(bundle: TestSupport.bundle(media: media, annotations: annotations))
    }

    /// Draws with `tool` by dragging through `points`.
    static func draw(_ editor: inout AnnotationEditor, _ tool: EditorTool, _ points: [CGPoint]) {
        editor.setTool(tool)
        drag(&editor, points)
    }

    static func drag(_ editor: inout AnnotationEditor, _ points: [CGPoint]) {
        editor.beginGesture(at: points[0])
        for point in points.dropFirst() {
            editor.updateGesture(to: point)
        }
        editor.endGesture()
    }

    static func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: Drawing each shape

    @Test func drawsEveryShapeAndReturnsToSelect() {
        var editor = Self.editor()
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        #expect(editor.bundle.annotations.last?.shape == .rect(NormRect(x: 1000, y: 2000, width: 2000, height: 2000)))
        #expect(editor.tool == .select)
        #expect(editor.selection == "a1")

        Self.draw(&editor, .strike, [Self.p(300, 200), Self.p(100, 100)]) // dragged up-left
        #expect(editor.bundle.annotations.last?.shape == .strike(NormRect(x: 1000, y: 2000, width: 2000, height: 2000)))

        Self.draw(&editor, .arrow, [Self.p(10, 10), Self.p(50, 50), Self.p(500, 250)])
        #expect(editor.bundle.annotations.last?.shape == .arrow(points: [NormPoint(x: 100, y: 200), NormPoint(x: 5000, y: 5000)]))

        Self.draw(&editor, .insertion, [Self.p(400, 100)])
        #expect(editor.bundle.annotations.last?.shape == .insertion(NormPoint(x: 4000, y: 2000)))

        Self.draw(&editor, .freehand, [Self.p(0, 0), Self.p(50, 0), Self.p(50, 50), Self.p(0, 50)])
        #expect(editor.bundle.annotations.last?.shape == .freehand(
            points: [NormPoint(x: 0, y: 0), NormPoint(x: 500, y: 0), NormPoint(x: 500, y: 1000), NormPoint(x: 0, y: 1000)],
            closed: true
        ))
        #expect(editor.bundle.annotations.map(\.id) == ["a1", "a2", "a3", "a4", "a5"])
        #expect(editor.bundle.annotations.allSatisfy { $0.intents.isEmpty && $0.note.isEmpty && $0.mediaId == "m1" })
        #expect(editor.bundle.validate().isEmpty)
    }

    @Test func tinyDragsDrawNothingAndKeepTheTool() {
        var editor = Self.editor()
        for tool in [EditorTool.rect, .strike, .arrow, .freehand] {
            Self.draw(&editor, tool, [Self.p(100, 100), Self.p(102, 103)])
            #expect(editor.bundle.annotations.isEmpty, "\(tool)")
            #expect(editor.tool == tool)
            #expect(!editor.canUndo)
        }
        // A freehand stroke needs three distinct points even when long enough.
        Self.draw(&editor, .freehand, [Self.p(0, 0), Self.p(300, 0)])
        #expect(editor.bundle.annotations.isEmpty)
    }

    @Test func drawingPreviewsWhileDraggingAndOutOfBoundsPointsClamp() {
        var editor = Self.editor()
        editor.setTool(.rect)
        editor.beginGesture(at: Self.p(-50, -50))
        #expect(editor.previewShape == nil)
        editor.updateGesture(to: Self.p(2000, 900))
        #expect(editor.previewShape == .rect(NormRect(x: 0, y: 0, width: 10000, height: 10000)))
        editor.endGesture()
        #expect(editor.bundle.validate().isEmpty)
    }

    // MARK: Select, move, resize

    @Test func clickSelectsMovesAndResizesWithOneUndoStepEach() {
        var editor = Self.editor()
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        editor.select(nil)

        Self.drag(&editor, [Self.p(200, 150)]) // click inside: select, no change
        #expect(editor.selection == "a1")
        #expect(editor.canUndo) // only the draw

        let undoDepth = editor.undoStack.count
        Self.drag(&editor, [Self.p(200, 150), Self.p(220, 160), Self.p(250, 170)])
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 1500, y: 2400, width: 2000, height: 2000)))
        #expect(editor.undoStack.count == undoDepth + 1)

        // Bottom-right handle at (350, 220).
        Self.drag(&editor, [Self.p(351, 221), Self.p(500, 300)])
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 1500, y: 2400, width: 3500, height: 3600)))
        #expect(editor.undoStack.count == undoDepth + 2)

        editor.undo()
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 1500, y: 2400, width: 2000, height: 2000)))
        editor.undo()
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 1000, y: 2000, width: 2000, height: 2000)))
    }

    @Test func movesStopAtTheMediaEdge() {
        var editor = Self.editor()
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        Self.drag(&editor, [Self.p(200, 150), Self.p(5000, -5000)])
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 8000, y: 0, width: 2000, height: 2000)))
        #expect(editor.bundle.validate().isEmpty)
    }

    @Test func resizeNeverFlipsOrShrinksBelowTheMinimum() {
        var editor = Self.editor()
        editor.minimumSide = 10
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        // Drag the top-left handle far past the bottom-right corner.
        Self.drag(&editor, [Self.p(100, 100), Self.p(900, 450)])
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 2900, y: 3800, width: 100, height: 200)))
    }

    @Test func arrowVerticesAndFreehandBoxesResize() {
        var editor = Self.editor()
        Self.draw(&editor, .arrow, [Self.p(100, 100), Self.p(300, 100)])
        Self.drag(&editor, [Self.p(300, 100), Self.p(300, 400)]) // drag the head
        #expect(editor.bundle.annotations[0].shape == .arrow(points: [NormPoint(x: 1000, y: 2000), NormPoint(x: 3000, y: 8000)]))

        Self.draw(&editor, .freehand, [Self.p(0, 0), Self.p(100, 0), Self.p(100, 100)])
        Self.drag(&editor, [Self.p(100, 100), Self.p(200, 200)]) // bottom-right box handle doubles it
        #expect(editor.bundle.annotations[1].shape == .freehand(
            points: [NormPoint(x: 0, y: 0), NormPoint(x: 2000, y: 0), NormPoint(x: 2000, y: 4000)], closed: true
        ))
    }

    @Test func clickingEmptySpaceDeselectsAndNestedShapesStaySelectable() {
        var editor = Self.editor()
        Self.draw(&editor, .rect, [Self.p(0, 0), Self.p(800, 400)])
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(200, 200)])
        Self.draw(&editor, .rect, [Self.p(50, 50), Self.p(700, 350)]) // drawn last, covers the small one
        Self.drag(&editor, [Self.p(150, 150)])
        #expect(editor.selection == "a2") // the smallest hit wins over the topmost
        Self.drag(&editor, [Self.p(900, 450)])
        #expect(editor.selection == nil)
    }

    // MARK: Cancel (Esc)

    @Test func cancelRestoresEveryKindOfGesture() {
        var editor = Self.editor()
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        let before = editor.bundle
        let depth = editor.undoStack.count

        editor.beginGesture(at: Self.p(200, 150)) // move
        editor.updateGesture(to: Self.p(600, 400))
        #expect(editor.bundle != before) // live preview
        editor.cancelGesture()
        #expect(editor.bundle == before)

        editor.beginGesture(at: Self.p(300, 200)) // resize
        editor.updateGesture(to: Self.p(900, 450))
        editor.cancelGesture()
        #expect(editor.bundle == before)

        editor.setTool(.arrow) // draw
        editor.beginGesture(at: Self.p(10, 10))
        editor.updateGesture(to: Self.p(500, 400))
        editor.cancelGesture()
        #expect(editor.bundle == before)
        #expect(editor.tool == .arrow)

        editor.setTool(.crop)
        editor.beginGesture(at: Self.p(10, 10))
        editor.updateGesture(to: Self.p(500, 400))
        #expect(editor.previewCrop == CGRect(x: 10, y: 10, width: 490, height: 390))
        editor.cancelGesture()
        #expect(editor.bundle == before && editor.previewCrop == nil)
        #expect(editor.undoStack.count == depth)
        editor.endGesture() // nothing to end
        #expect(editor.undoStack.count == depth)
    }

    @Test func interruptedGesturesNeverLeakState() {
        var editor = Self.editor(media: [Self.media("m1"), Self.media("m2")])
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        let before = editor.bundle
        // Begin a move, then switch media mid-drag: the move is cancelled.
        editor.beginGesture(at: Self.p(200, 150))
        editor.updateGesture(to: Self.p(700, 400))
        editor.show(mediaId: "m2")
        #expect(editor.bundle == before && editor.gesture == nil)
        // Undo mid-drag cancels first, then undoes the draw.
        editor.show(mediaId: "m1")
        editor.select("a1")
        editor.beginGesture(at: Self.p(200, 150))
        editor.updateGesture(to: Self.p(700, 400))
        editor.undo()
        #expect(editor.bundle.annotations.isEmpty)
        // A second begin without an end restarts cleanly.
        editor.setTool(.rect)
        editor.beginGesture(at: Self.p(0, 0))
        editor.beginGesture(at: Self.p(10, 10))
        editor.updateGesture(to: Self.p(100, 100))
        editor.endGesture()
        #expect(editor.bundle.annotations.map(\.shape) == [.rect(NormRect(x: 100, y: 200, width: 900, height: 1800))])
        // Updates and ends without a gesture are ignored.
        editor.updateGesture(to: Self.p(5, 5))
        editor.endGesture()
        #expect(editor.bundle.annotations.count == 1)
    }
}

/// Notes, intents, history, and media merging.
extension AnnotationEditorTests {
    // MARK: Notes, intents, undo coalescing

    @Test func typingANoteIsOneUndoStepPerAnnotation() {
        var editor = Self.editor()
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        Self.draw(&editor, .rect, [Self.p(400, 100), Self.p(600, 200)])
        let depth = editor.undoStack.count
        for text in ["L", "La", "Lab", "Label"] {
            editor.setNote(text, for: "a1")
        }
        #expect(editor.undoStack.count == depth + 1)
        editor.setNote("Other", for: "a2") // a different note starts a new step
        editor.setNote("Label clipped", for: "a1") // and returning to the first does too
        #expect(editor.undoStack.count == depth + 3)
        editor.undo()
        #expect(editor.annotation("a1")?.note == "Label")
        editor.undo()
        #expect(editor.annotation("a2")?.note == "")
        editor.undo()
        #expect(editor.annotation("a1")?.note == "")
        // Typing after an undo starts a fresh step and clears redo.
        editor.setNote("New", for: "a1")
        #expect(!editor.canRedo)
        editor.setNote("New text", for: "a1")
        editor.undo()
        #expect(editor.annotation("a1")?.note == "")
    }

    @Test func noOpEditsLeaveHistoryAlone() {
        var editor = Self.editor()
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        let depth = editor.undoStack.count
        let result1 = editor.setNote("", for: "a1")
        #expect(!result1)
        let result2 = editor.setNote("x", for: "missing")
        #expect(!result2)
        let result3 = editor.toggleIntent(.bug, for: "missing")
        #expect(!result3)
        let result4 = editor.setClosed(false, for: "a1")
        #expect(!result4) // not freehand
        let result5 = editor.toggleIntent(.comment, for: "a1")
        #expect(!result5) // removing the only (default) intent
        #expect(editor.undoStack.count == depth)
    }

    @Test func intentsToggleOverTheEffectiveSet() {
        let strike = Shape.strike(NormRect(x: 0, y: 0, width: 10, height: 10))
        #expect(IntentToggle.toggled([], .bug, shape: strike) == [.bug, .remove]) // default kept, canonical order
        #expect(IntentToggle.toggled([.bug, .remove], .bug, shape: strike) == []) // back to the default
        #expect(IntentToggle.toggled([], .remove, shape: strike) == []) // can't drop the last one
        #expect(IntentToggle.toggled([.bug, .remove], .remove, shape: strike) == [.bug]) // explicit replaces default
        #expect(IntentToggle.toggled([.bug], .bug, shape: strike) == []) // empty → default
        #expect(IntentToggle.toggled([.question], .comment, shape: .insertion(NormPoint(x: 1, y: 1))) == [.comment, .question])
        // Every intent on every shape: the result is canonical and never the bare default.
        for shape in [strike, .rect(NormRect(x: 0, y: 0, width: 1, height: 1)), .insertion(NormPoint(x: 0, y: 0))] {
            for intent in Intent.allCases {
                let once = IntentToggle.toggled([], intent, shape: shape)
                #expect(once != [shape.defaultIntent])
                #expect(once == Intent.allCases.filter(once.contains))
                #expect(IntentToggle.toggled(once, intent, shape: shape) == [], "\(shape.kind) \(intent)")
            }
        }
    }

    @Test func primaryIntentPrefersWhatTheReviewerAdded() {
        let rect = Shape.rect(NormRect(x: 0, y: 0, width: 10, height: 10))
        func primary(_ intents: [Intent], _ shape: Shape = rect) -> Intent {
            Annotation(id: "a", mediaId: "m", shape: shape, intents: intents, note: "").primaryIntent
        }
        #expect(primary([]) == .comment)
        #expect(primary([.comment, .bug]) == .bug)
        #expect(primary([.bug, .question]) == .bug)
        #expect(primary([.comment]) == .comment)
        #expect(primary([.bug, .remove], .strike(NormRect(x: 0, y: 0, width: 1, height: 1))) == .bug)
    }

    @Test func freehandOutlinesOpenAndClose() {
        var editor = Self.editor()
        Self.draw(&editor, .freehand, [Self.p(0, 0), Self.p(100, 0), Self.p(100, 100)])
        let result6 = editor.setClosed(false, for: "a1")
        #expect(result6)
        guard case .freehand(_, false) = editor.bundle.annotations[0].shape else {
            Issue.record("expected an open outline")
            return
        }
        editor.undo()
        guard case .freehand(_, true) = editor.bundle.annotations[0].shape else {
            Issue.record("expected a closed outline")
            return
        }
    }

    // MARK: Delete, duplicate, nudge, Tab

    @Test func deleteDuplicateAndNudge() {
        var editor = Self.editor()
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        editor.setNote("Copy me", for: "a1")
        editor.toggleIntent(.bug, for: "a1")
        let result7 = editor.duplicateSelection()
        #expect(result7)
        #expect(editor.selection == "a2")
        #expect(editor.annotation("a2")?.note == "Copy me")
        #expect(editor.annotation("a2")?.intents == [.comment, .bug])
        #expect(editor.annotation("a2")?.shape == .rect(NormRect(x: 1200, y: 2200, width: 2000, height: 2000)))

        let depth = editor.undoStack.count
        for _ in 0 ..< 5 {
            editor.nudgeSelection(dx: 1, dy: 0)
        }
        editor.nudgeSelection(dx: 0, dy: -10)
        #expect(editor.annotation("a2")?.shape == .rect(NormRect(x: 1250, y: 2000, width: 2000, height: 2000)))
        #expect(editor.undoStack.count == depth + 1) // one step for the run of nudges

        let result8 = editor.deleteSelection()
        #expect(result8)
        #expect(editor.selection == nil && editor.annotation("a2") == nil)
        let result9 = editor.deleteSelection()
        #expect(!result9)
        let result10 = editor.duplicateSelection()
        #expect(!result10)
        let result11 = editor.nudgeSelection(dx: 1, dy: 1)
        #expect(!result11)
        editor.undo()
        #expect(editor.selection == "a2") // undo restores the selection too
        // Ids are never reused after a delete.
        editor.deleteSelection()
        Self.draw(&editor, .rect, [Self.p(500, 100), Self.p(700, 200)])
        #expect(editor.bundle.annotations.map(\.id) == ["a1", "a3"])
    }

    @Test func tabCyclesTheCurrentMediaOnly() {
        var editor = Self.editor(media: [Self.media("m1"), Self.media("m2")])
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        Self.draw(&editor, .rect, [Self.p(400, 100), Self.p(600, 200)])
        editor.show(mediaId: "m2")
        Self.draw(&editor, .insertion, [Self.p(5, 5)])
        editor.show(mediaId: "m1")
        editor.selectNext()
        #expect(editor.selection == "a1")
        editor.selectNext()
        editor.selectNext()
        #expect(editor.selection == "a1")
        editor.selectNext(forward: false)
        #expect(editor.selection == "a2")
        editor.select(nil)
        editor.selectNext(forward: false)
        #expect(editor.selection == "a2")
        #expect(editor.number(of: "a3") == 3)
        #expect(editor.annotations(on: "m2").map(\.id) == ["a3"])
    }

    // MARK: Undo / redo walks

    @Test func undoAndRedoWalkTheWholeHistoryAndRestoreTheMedia() {
        var editor = Self.editor(media: [Self.media("m1"), Self.media("m2")])
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)]) // m1
        editor.show(mediaId: "m2")
        Self.draw(&editor, .arrow, [Self.p(0, 0), Self.p(300, 300)]) // m2
        editor.setNote("Move it", for: "a2")
        let final = editor.bundle

        var states = [final]
        while editor.canUndo {
            editor.undo()
            states.append(editor.bundle)
        }
        #expect(editor.bundle.annotations.isEmpty)
        #expect(editor.currentMediaId == "m1") // jumped back to where the first change happened
        editor.undo() // past the beginning: no-op
        #expect(editor.bundle.annotations.isEmpty)

        var replayed = [editor.bundle]
        while editor.canRedo {
            editor.redo()
            replayed.append(editor.bundle)
        }
        #expect(replayed == states.reversed())
        #expect(editor.currentMediaId == "m2")
        editor.redo() // past the end: no-op
        #expect(editor.bundle == final)

        // A new change after undo discards the redo branch.
        editor.undo()
        editor.toggleIntent(.question, for: "a2")
        #expect(!editor.canRedo)
    }

    @Test func historyIsBounded() {
        var editor = Self.editor()
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        for _ in 0 ..< AnnotationEditor.undoLimit + 20 {
            editor.toggleIntent(.bug, for: "a1")
        }
        #expect(editor.undoStack.count == AnnotationEditor.undoLimit)
    }

    @Test func dirtyTracksTheSavedDocument() {
        var editor = Self.editor()
        #expect(!editor.isDirty)
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        #expect(editor.isDirty)
        editor.markSaved()
        #expect(!editor.isDirty)
        editor.undo()
        #expect(editor.isDirty)
        editor.redo()
        #expect(!editor.isDirty)
        editor.select(nil) // navigation never dirties
        editor.setTool(.arrow)
        #expect(!editor.isDirty)
    }

    // MARK: Media captured while editing

    @Test func capturesAddedWhileEditingSurviveUndo() {
        var editor = Self.editor()
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        editor.markSaved()
        var disk = editor.bundle
        disk.media.append(Self.media("m2", filename: "capture-2.png"))
        let result12 = editor.mergeMedia(from: disk)
        #expect(result12 == ["m2"])
        #expect(editor.mergeMedia(from: disk).isEmpty) // idempotent
        #expect(!editor.isDirty) // the disk already has it
        editor.undo()
        #expect(editor.bundle.media.map(\.id) == ["m1", "m2"])
        editor.redo()
        #expect(editor.bundle.media.map(\.id) == ["m1", "m2"])
        editor.show(mediaId: "m2")
        Self.draw(&editor, .insertion, [Self.p(1, 1)])
        #expect(editor.bundle.validate().isEmpty)
    }

    @Test func mergingDuringAGestureKeepsTheCaptureAfterCancel() {
        var editor = Self.editor()
        Self.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)])
        editor.beginGesture(at: Self.p(200, 150))
        editor.updateGesture(to: Self.p(400, 300))
        var disk = editor.bundle
        disk.media.append(Self.media("m2"))
        editor.mergeMedia(from: disk)
        editor.cancelGesture()
        #expect(editor.bundle.media.count == 2)
    }

    @Test func anEmptyReviewAcceptsNothingUntilMediaArrives() {
        var editor = AnnotationEditor(bundle: TestSupport.bundle(media: []))
        #expect(editor.currentMediaId == nil)
        Self.draw(&editor, .rect, [Self.p(0, 0), Self.p(100, 100)])
        #expect(editor.bundle.annotations.isEmpty && !editor.canUndo)
        editor.selectNext()
        let result13 = editor.crop(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(!result13)
        editor.mergeMedia(from: TestSupport.bundle(media: [Self.media()]))
        #expect(editor.currentMediaId == "m1")
        Self.draw(&editor, .rect, [Self.p(0, 0), Self.p(100, 100)])
        #expect(editor.bundle.annotations.count == 1)
    }

    @Test func toolShortcuts() {
        #expect(EditorTool.forShortcut("R") == .rect)
        #expect(EditorTool.forShortcut("v") == .select)
        #expect(EditorTool.forShortcut("x") == nil)
        #expect(Set(EditorTool.allCases.map(\.shortcut)).count == EditorTool.allCases.count)
    }
}
