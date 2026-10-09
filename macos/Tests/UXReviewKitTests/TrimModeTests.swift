import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// HS2-ECE7WY: Trim mode. States: off / on (handles moved or not); transitions: enter, move a
/// handle, frame-step a handle, Trim, Cancel, and what ends or is refused during the mode (undo,
/// showing another capture, tools, canvas gestures, edits). The clip is 4 s.
struct TrimModeTests {
    typealias Video = VideoTimeTests
    static func range(_ start: Int, _ end: Int) -> TimeRange { TimeRange(startMs: start, endMs: end) }

    static func editor() -> AnnotationEditor {
        Video.clipEditor(annotations: [Video.box("a1", range(500, 1500)), Video.box("a2", nil)], extraImage: true)
    }

    @Test func enteringShowsTheWholeOriginalAndKeepsTheDocumentToSave() {
        var editor = Self.editor()
        let done1 = editor.trim(to: Self.range(1000, 3000))
        #expect(done1)
        editor.setCurrentTime(500) // 1500 ms into the original
        editor.select("a2")
        let trimmed = editor.document
        let done2 = editor.enterTrimMode()
        #expect(done2)
        #expect(editor.trimMode?.range == Self.range(1000, 3000))
        #expect(editor.trimMode?.originalMs == 4000)
        #expect(editor.currentDurationMs == 4000 && editor.document.trims["v1"] == nil)
        #expect(editor.currentTimeMs == 1500, "the same frame, in the original's time")
        #expect(editor.bundle.annotations[0].timeRange == Self.range(500, 1500), "ranges in the original's time")
        #expect(editor.selection == nil)
        #expect(editor.persistentDocument == trimmed, "saving writes the review as it was")
        let again = editor.enterTrimMode()
        #expect(!again, "already on")
    }

    @Test func onlyVideosEnterTrimMode() {
        var editor = Self.editor()
        editor.show(mediaId: "m2")
        let entered = editor.enterTrimMode()
        #expect(!editor.canTrim && !entered && editor.trimMode == nil)
    }

    @Test func handlesStayApartAndInsideTheMovie() {
        var editor = Self.editor()
        editor.enterTrimMode()
        editor.setTrimModeEnd(.trimStart, toMs: 1200)
        #expect(editor.trimMode?.range == Self.range(1200, 4000) && editor.currentTimeMs == 1200)
        editor.setTrimModeEnd(.trimEnd, toMs: 9999)
        #expect(editor.trimMode?.range == Self.range(1200, 4000))
        editor.setTrimModeEnd(.trimEnd, toMs: 1000) // before the start: stops the minimum after it
        #expect(editor.trimMode?.range == Self.range(1200, 1200 + AnnotationEditor.minimumTrimMs))
        editor.setTrimModeEnd(.trimStart, toMs: -50)
        #expect(editor.trimMode?.range.startMs == 0)
        editor.setTrimModeEnd(.rangeStart, toMs: 3000) // not a trim handle: ignored
        #expect(editor.trimMode?.range.startMs == 0)
    }

    @Test func trimAppliesTheRangeAsOneUndoStep() {
        var editor = Self.editor()
        editor.enterTrimMode()
        editor.setTrimModeEnd(.trimStart, toMs: 1000)
        editor.setTrimModeEnd(.trimEnd, toMs: 3000)
        let done3 = editor.commitTrimMode()
        #expect(done3)
        #expect(editor.trimMode == nil)
        #expect(editor.document.trims["v1"] == Self.range(1000, 3000) && editor.currentDurationMs == 2000)
        #expect(editor.bundle.annotations[0].timeRange == Self.range(-500, 500))
        editor.undo()
        #expect(editor.document.trims["v1"] == nil && editor.currentDurationMs == 4000)
        editor.redo()
        #expect(editor.document.trims["v1"] == Self.range(1000, 3000))
    }

    @Test func trimmingAgainStartsFromTheTrimAndCanGoBackToTheWholeMovie() {
        var editor = Self.editor()
        let done4 = editor.trim(to: Self.range(1000, 3000))
        #expect(done4)
        editor.enterTrimMode()
        #expect(editor.trimMode?.range == Self.range(1000, 3000))
        editor.setTrimModeEnd(.trimStart, toMs: 500) // widen past the old start
        editor.commitTrimMode()
        #expect(editor.document.trims["v1"] == Self.range(500, 3000))
        editor.enterTrimMode()
        editor.setTrimModeEnd(.trimStart, toMs: 0)
        editor.setTrimModeEnd(.trimEnd, toMs: 4000)
        editor.commitTrimMode()
        #expect(editor.document.trims["v1"] == nil && editor.currentDurationMs == 4000)
        #expect(editor.bundle.annotations[0].timeRange == Self.range(500, 1500), "ranges back exactly")
    }

    @Test func trimWithTheRangeUnchangedOrCancelChangesNothing() {
        var editor = Self.editor()
        let done5 = editor.trim(to: Self.range(1000, 3000))
        #expect(done5)
        editor.setCurrentTime(700)
        editor.select("a2")
        let before = (editor.document, editor.currentTimeMs, editor.selection, editor.canUndo)
        editor.enterTrimMode()
        editor.commitTrimMode() // nothing moved
        #expect(editor.document == before.0 && editor.currentTimeMs == before.1 && editor.selection == before.2)
        editor.enterTrimMode()
        editor.setTrimModeEnd(.trimEnd, toMs: 2000)
        let done6 = editor.cancelTrimMode()
        #expect(done6)
        #expect(editor.trimMode == nil && editor.document == before.0 && editor.currentTimeMs == before.1 && editor.selection == before.2)
        editor.undo() // the only undo step is the trim before the mode
        #expect(editor.document.trims["v1"] == nil)
        let cancelled = editor.cancelTrimMode(), committed = editor.commitTrimMode()
        #expect(!cancelled && !committed, "not on")
    }

    @Test func duringTheModeNothingElseChangesTheReview() {
        var editor = Self.editor()
        editor.enterTrimMode()
        let working = editor.document
        let ranged = editor.setTimeRange(Self.range(0, 100), for: "a1")
        #expect(!ranged)
        editor.setTool(.rect)
        #expect(editor.tool == .select)
        editor.beginGesture(at: CGPoint(x: 100, y: 100))
        #expect(editor.gesture == nil)
        let restored = editor.restoreOriginal(), trimmed = editor.trim(to: Self.range(0, 1000))
        #expect(!restored && !trimmed)
        #expect(editor.document == working && editor.trimMode != nil)
        // The playhead still moves, and plays across the whole movie.
        editor.setCurrentTime(3500)
        #expect(editor.currentTimeMs == 3500)
    }

    @Test func undoShowingAnotherCaptureOrMediaChangesEndTheModeUnchanged() {
        var editor = Self.editor()
        let done7 = editor.trim(to: Self.range(1000, 3000))
        #expect(done7)
        let trimmed = editor.document
        editor.enterTrimMode()
        editor.setTrimModeEnd(.trimEnd, toMs: 2000)
        editor.undo() // leaves the mode; doesn't undo the earlier trim
        #expect(editor.trimMode == nil && editor.document == trimmed)
        editor.enterTrimMode()
        editor.show(mediaId: "v1") // the same capture: still on
        #expect(editor.trimMode != nil)
        editor.show(mediaId: "m2")
        #expect(editor.trimMode == nil && editor.document == trimmed)
        editor.show(mediaId: "v1")
        editor.enterTrimMode()
        _ = editor.syncMedia(with: editor.persistentDocument.bundle)
        #expect(editor.trimMode == nil && editor.document == trimmed)
    }

    @Test func frameStepsMoveTheLastUsedHandle() {
        var editor = Self.editor()
        editor.enterTrimMode()
        editor.setTrimModeEnd(.trimStart, toMs: 1000)
        let done8 = editor.stepFrames(1, target: .trimStart)
        #expect(done8)
        let start = editor.trimMode?.range.startMs ?? 0
        #expect(start > 1000 && start < 1100)
        let done9 = editor.stepFrames(-1, target: .trimStart)
        #expect(done9)
        #expect(editor.trimMode?.range.startMs == 1000)
        let done10 = editor.stepFrames(-1, target: .trimEnd)
        #expect(done10)
        #expect((editor.trimMode?.range.endMs ?? 0) < 4000)
        // Nothing is applied until Trim.
        #expect(editor.document.trims["v1"] == nil && !editor.canUndo)
    }
}
