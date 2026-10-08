import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// ← / → frame steps (docs/06-annotation-editor.md §6.4, §6.10, `HS2-8FTZ09`). States: the stored
/// last-used target (none / playhead / trim start / trim end / range start / range end) crossed
/// with what the resolution sees (selection, ranged or whole-clip annotation, video or image).
/// Transitions: every action that sets or clears the target, and the ones that make a range
/// target disappear (delete, deselect, other selection, whole clip, media switch, removal).
/// The clip is 4000 ms at 10 fps (100 ms frames) unless a test says otherwise.
struct FrameStepTests {
    typealias Clip = VideoTimeTests
    typealias Fixture = AnnotationEditorTests

    static func editor(_ range: TimeRange? = Clip.range(1000, 2000), select: Bool = true, fps: Double? = 10) -> AnnotationEditor {
        var editor = Clip.clipEditor(
            annotations: [Clip.box("a1", range), Clip.box("a2", Clip.range(3000, 3500), x: 5000)],
            extraImage: true
        )
        editor.setFrameRate(fps, for: "v1")
        if select { editor.select("a1") }
        return editor
    }

    // MARK: Frame grid

    @Test func frameTimesSnapToTheMovieFrames() {
        var editor = Self.editor(fps: 30)
        #expect(editor.frameRate(of: "v1") == 30)
        #expect(editor.frameTime(from: 0, frames: 1, of: "v1") == 34, "frame 1 starts at 33.3 ms: the first whole ms inside it")
        #expect(editor.frameTime(from: 34, frames: 1, of: "v1") == 67)
        #expect(editor.frameTime(from: 33, frames: 1, of: "v1") == 34, "33 ms still shows frame 0")
        #expect(editor.frameTime(from: 50, frames: -1, of: "v1") == 34, "back from inside a frame: that frame's start")
        #expect(editor.frameTime(from: 34, frames: -1, of: "v1") == 0)
        #expect(editor.frameTime(from: 0, frames: 10, of: "v1") == 334)
        #expect(editor.frameTime(from: 1000, frames: -10, of: "v1") == 667)
        // A trim keeps the movie's grid: the clip starts 50 ms in, inside frame 1 (34…66).
        editor.trim(to: Clip.range(50, 4000))
        #expect(editor.frameTime(from: 0, frames: 1, of: "v1") == 17, "frame 2 starts at 67 ms of the movie")
        #expect(editor.frameTime(from: 0, frames: -1, of: "v1") == -16, "frame 1 starts before the clip")
        editor.setFrameRate(25, for: "v1")
        #expect(editor.frameTime(from: 30, frames: 1, of: "v1") == 70, "25 fps: frames every 40 ms of the movie")
    }

    @Test func anUnknownOrNonsenseRateFallsBackTo30Fps() {
        var editor = Self.editor(fps: nil)
        #expect(editor.frameRate(of: "v1") == AnnotationEditor.defaultFrameRate)
        for rate in [0, -5, .nan, .infinity, 0.5] {
            editor.setFrameRate(rate, for: "v1")
            #expect(editor.frameRate(of: "v1") == 30, "rate \(rate)")
        }
        editor.setFrameRate(59.94, for: "v1")
        #expect(editor.frameRate(of: "v1") == 59.94)
    }

    // MARK: Which target (transition matrix)

    @Test func everyTimelineActionSetsTheLastUsedTarget() {
        let actions: [(String, (inout AnnotationEditor) -> Void, TimelineStepTarget)] = [
            ("scrub", { $0.movePlayhead(to: 1500) }, .playhead),
            (", / .", { $0.stepTime(forward: true) }, .playhead),
            ("trim-start drag", { $0.beginTimelineDrag(.trimStart) }, .trimStart),
            ("trim-end drag", { $0.beginTimelineDrag(.trimEnd) }, .trimEnd),
            ("range-start drag", { $0.beginTimelineDrag(.rangeStart) }, .rangeStart("a1")),
            ("range-end drag", { $0.beginTimelineDrag(.rangeEnd) }, .rangeEnd("a1")),
            ("typed From", { $0.setRangeEnd(.rangeStart, toMs: 900, for: "a1") }, .rangeStart("a1")),
            ("typed To", { $0.setRangeEnd(.rangeEnd, toMs: 2100, for: "a1") }, .rangeEnd("a1")),
            ("Trim Start", { $0.setCurrentTime(500); $0.trimStartToPlayhead() }, .trimStart),
            ("Trim End", { $0.setCurrentTime(3500); $0.trimEndToPlayhead() }, .trimEnd),
            ("frame step", { $0.stepFrames(1, target: .trimEnd) }, .trimEnd),
        ]
        for (name, action, expected) in actions {
            // From every starting target, the action wins.
            for start in [nil, TimelineStepTarget.playhead, .trimStart, .rangeEnd("a1")] {
                var editor = Self.editor()
                editor.timelineTarget = start
                action(&editor)
                editor.cancelTimelineDrag()
                #expect(editor.timelineTarget == expected, "\(name) from \(String(describing: start))")
                #expect(editor.frameStepTarget == expected, "\(name) resolves")
            }
        }
    }

    @Test func canvasActionsHandTheArrowsBackToTheShape() {
        let actions: [(String, (inout AnnotationEditor) -> Void)] = [
            ("press on a shape", { Fixture.drag(&$0, [Fixture.p(150, 100)]) }),
            ("draw", { Fixture.draw(&$0, .rect, [Fixture.p(600, 300), Fixture.p(700, 400)]) }),
            ("keyboard insert", { $0.setTool(.rect); $0.insertDefaultShape() }),
            ("duplicate", { $0.duplicateSelection() }),
            ("nudge ↑", { $0.nudgeSelection(dx: 0, dy: -1) }),
            ("select another", { $0.select("a2") }),
            ("Tab", { $0.selectNext() }),
        ]
        for (name, action) in actions {
            var editor = Self.editor()
            editor.movePlayhead(to: 1500)
            action(&editor)
            #expect(editor.timelineTarget == nil, "\(name)")
            #expect(editor.selection != nil, "\(name) leaves a selection")
            #expect(editor.frameStepTarget == nil, "\(name): the arrows nudge")
        }
        // Re-selecting the same annotation (its list row again) keeps the target.
        var same = Self.editor()
        same.beginTimelineDrag(.rangeEnd)
        same.endTimelineDrag()
        same.select("a1")
        #expect(same.frameStepTarget == .rangeEnd("a1"))
    }

    @Test func navigationAndHistoryKeepOrResetTheTarget() {
        var editor = Self.editor()
        editor.stepFrames(-1, target: .trimEnd)
        editor.undo()
        #expect(editor.timelineTarget == .trimEnd, "undo is not a target change")
        editor.redo()
        #expect(editor.timelineTarget == .trimEnd)
        editor.setCurrentTime(100) // playback ticks and reveals are not the reviewer's choice
        #expect(editor.timelineTarget == .trimEnd)
        editor.show(mediaId: "m2")
        #expect(editor.timelineTarget == nil && editor.frameStepTarget == nil, "an image has no timeline")
        editor.show(mediaId: "v1")
        #expect(editor.frameStepTarget == .playhead, "a video with nothing selected: the playhead")
        editor.movePlayhead(to: 0)
        editor.show(mediaId: "m2")
        editor.movePlayhead(to: 50)
        #expect(editor.timelineTarget == nil, "no playhead on an image")
    }

    // MARK: Fallbacks when the target disappears

    @Test func aRangeTargetFallsBackToThePlayheadWhenItsAnnotationGoes() {
        var deleted = Self.editor()
        deleted.stepFrames(1, target: .rangeEnd("a1"))
        deleted.deleteSelection()
        #expect(deleted.frameStepTarget == .playhead)
        let time = deleted.currentTimeMs
        deleted.arrowKey(forward: true)
        #expect(deleted.currentTimeMs == time + 100, "steps the playhead")
        #expect(deleted.annotation("a2")?.timeRange == Clip.range(3000, 3500))

        var deselected = Self.editor()
        deselected.stepFrames(1, target: .rangeStart("a1"))
        deselected.select(nil)
        #expect(deselected.frameStepTarget == .playhead)

        var whole = Self.editor()
        whole.stepFrames(1, target: .rangeEnd("a1"))
        whole.setTimeRange(nil, for: "a1")
        #expect(whole.timelineTarget == .rangeEnd("a1") && whole.frameStepTarget == .playhead, "a whole-clip annotation has no ends")
        whole.arrowKey(forward: false)
        #expect(whole.annotation("a1")?.timeRange == nil && whole.timelineTarget == .playhead)

        var undone = Self.editor()
        undone.stepFrames(1, target: .rangeEnd("a1"))
        undone.deleteSelection()
        undone.undo()
        #expect(undone.frameStepTarget == .rangeEnd("a1"), "undo brings the annotation, its selection, and the target back")
    }

    @Test func removingOrSwitchingToAnImageLeavesNoTimelineTarget() {
        var editor = Self.editor()
        editor.stepFrames(-1, target: .trimEnd)
        editor.dropMedia(["v1"])
        #expect(editor.currentMediaId == "m2" && editor.frameStepTarget == nil)
        let moved1 = editor.arrowKey(forward: true)
        #expect(!moved1, "nothing selected on the image: nothing happens")
        var image = Self.editor()
        image.select(nil)
        image.show(mediaId: "m2")
        image.setTool(.rect)
        image.insertDefaultShape()
        let before = image.selectedAnnotation?.shape
        image.arrowKey(forward: true, large: true)
        #expect(image.selectedAnnotation?.shape == before?.translated(dx: 100, dy: 0), "images: ⇧→ nudges 10 px")
    }

    // MARK: The ← / → rule

    @Test func arrowsNudgeAfterACanvasActionAndStepAfterATimelineAction() {
        var editor = Self.editor()
        let shape = editor.annotation("a1")?.shape
        editor.setCurrentTime(1500)
        editor.arrowKey(forward: true)
        #expect(editor.annotation("a1")?.shape == shape?.translated(dx: 10, dy: 0), "selected shape, no timeline use: nudge 1 px")
        #expect(editor.currentTimeMs == 1500)
        editor.movePlayhead(to: 1500)
        editor.arrowKey(forward: true)
        editor.arrowKey(forward: true, large: true)
        #expect(editor.currentTimeMs == 2600, "after scrubbing: 1 + 10 frames of the playhead")
        #expect(editor.annotation("a1")?.shape == shape?.translated(dx: 10, dy: 0), "the shape stays put")
        editor.setCurrentTime(1500) // a1 shows again, so the press below hits it
        Fixture.drag(&editor, [Fixture.p(150, 100)])
        editor.arrowKey(forward: false)
        #expect(editor.annotation("a1")?.shape == shape, "a canvas press: back to nudging")
        editor.select(nil)
        editor.arrowKey(forward: false)
        #expect(editor.currentTimeMs == 1400, "nothing selected on a video: the playhead")
    }

    // MARK: Playhead

    @Test func playheadStepsClampAndAreNotUndoable() {
        var editor = Self.editor(select: false)
        editor.movePlayhead(to: 1550)
        editor.arrowKey(forward: false)
        #expect(editor.currentTimeMs == 1500, "back from inside a frame: its start")
        editor.arrowKey(forward: false, large: true)
        #expect(editor.currentTimeMs == 500)
        editor.arrowKey(forward: false, large: true)
        #expect(editor.currentTimeMs == 0)
        let moved2 = editor.arrowKey(forward: false)
        #expect(!moved2, "nothing before the first frame")
        editor.movePlayhead(to: 3950)
        editor.arrowKey(forward: true, large: true)
        #expect(editor.currentTimeMs == 4000, "clamped to the clip end, which shows the last frame")
        #expect(!editor.canUndo && !editor.isDirty)
    }
}

/// Frame steps that edit (`HS2-8FTZ09`): trim ends and range ends, their limits, the playhead
/// following them, and undo coalescing. Same clip as `FrameStepTests`.
struct FrameStepEditTests {
    typealias Clip = VideoTimeTests

    static func editor(_ range: TimeRange? = Clip.range(1000, 2000), select: Bool = true) -> AnnotationEditor {
        FrameStepTests.editor(range, select: select)
    }

    // MARK: Trim ends

    @Test func trimEndStepsTrimAndCoalesceIntoOneUndoStep() {
        var editor = Self.editor()
        editor.beginTimelineDrag(.trimEnd)
        editor.endTimelineDrag() // released at the clip end: nothing trimmed, but now the target
        #expect(editor.frameStepTarget == .trimEnd && !editor.canUndo)
        editor.arrowKey(forward: false, large: true)
        #expect(editor.currentDurationMs == 3000 && editor.document.trims["v1"] == Clip.range(0, 3000))
        #expect(editor.currentTimeMs == 3000, "the playhead shows the new end, as when dragging")
        #expect(editor.annotation("a2")?.timeRange == Clip.range(3000, 3500), "ranges are kept exactly (HS2-71SSJG)")
        editor.arrowKey(forward: false)
        #expect(editor.currentDurationMs == 2900)
        #expect(editor.annotation("a2").map(editor.isOutsideEdit) == true, "outside the trim: hidden, not removed")
        #expect(
            editor.message == "Trimmed to 2.9 s. 1 annotation outside the trim is hidden."
        )
        editor.arrowKey(forward: true)
        #expect(editor.currentDurationMs == 3000, "stepping outward brings trimmed time back")
        editor.undo()
        #expect(editor.currentDurationMs == 4000 && editor.annotation("a2")?.timeRange == Clip.range(3000, 3500))
        #expect(!editor.canUndo, "consecutive steps of one end are one undo step")
        editor.redo()
        #expect(editor.currentDurationMs == 3000)
        #expect(editor.submissionBundle.validate().isEmpty)
    }

    @Test func trimEndStopsAtTheMinimumClipAndTheOriginalEnd() {
        var editor = Self.editor()
        let moved3 = editor.stepFrames(1, target: .trimEnd)
        #expect(!moved3, "already at the original's end")
        for _ in 0 ..< 3 {
            editor.stepFrames(-10, target: .trimEnd)
        }
        #expect(editor.currentDurationMs == 1000)
        editor.stepFrames(-10, target: .trimEnd)
        #expect(editor.currentDurationMs == AnnotationEditor.minimumTrimMs, "clamped to the shortest clip")
        let moved4 = editor.stepFrames(-1, target: .trimEnd)
        #expect(!moved4)
        editor.stepFrames(100, target: .trimEnd)
        #expect(editor.currentDurationMs == 4000 && editor.document.trims["v1"] == nil, "back to the whole original: no trim")
        #expect(!editor.canRestoreOriginal)
        #expect(
            editor.annotation("a1")?.timeRange == Clip.range(1000, 2000) && editor.annotation("a2")?.timeRange == Clip.range(3000, 3500),
            "annotations hidden on the way come back intact (HS2-71SSJG)"
        )
        editor.undo()
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2000))
    }

    @Test func trimStartStepsShiftRangesAndCanStepBackOut() {
        var editor = Self.editor()
        editor.movePlayhead(to: 1500)
        editor.beginTimelineDrag(.trimStart)
        editor.endTimelineDrag()
        #expect(editor.currentTimeMs == 1500, "a release at the start trims nothing and leaves the playhead")
        editor.arrowKey(forward: true)
        #expect(editor.document.trims["v1"] == Clip.range(100, 4000) && editor.currentDurationMs == 3900)
        #expect(editor.currentTimeMs == 0, "the playhead shows the new first frame")
        #expect(editor.annotation("a1")?.timeRange == Clip.range(900, 1900), "ranges move with the clip")
        editor.arrowKey(forward: true, large: true)
        #expect(editor.document.trims["v1"] == Clip.range(1100, 4000))
        #expect(editor.annotation("a1")?.timeRange == Clip.range(-100, 900), "exact, partly before the clip")
        editor.arrowKey(forward: false, large: true)
        editor.arrowKey(forward: false)
        #expect(editor.document.trims["v1"] == nil, "back to the whole original")
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2000), "nothing was cut off the range (HS2-71SSJG)")
        let moved5 = editor.arrowKey(forward: false)
        #expect(!moved5, "nothing before the original's start")
        editor.undo()
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2000))
        #expect(!editor.canUndo && editor.document.trims["v1"] == nil, "one coalesced step")
    }

    @Test func trimStartStopsAtTheMinimumClip() {
        var editor = Self.editor()
        editor.stepFrames(39, target: .trimStart)
        #expect(editor.currentDurationMs == 100)
        let moved6 = editor.stepFrames(1, target: .trimStart)
        #expect(!moved6)
        #expect(editor.bundle.annotations.allSatisfy(editor.isOutsideEdit) && editor.selection == nil)
        #expect(editor.submissionBundle.annotations.isEmpty)
    }

    @Test func trimStepsComposeWithEarlierTrimsOnTheOriginalGrid() {
        var editor = Self.editor(select: false)
        editor.trim(to: Clip.range(250, 4000)) // mid-frame: frame 2 is 200…299
        #expect(editor.document.trims["v1"] == Clip.range(250, 4000))
        editor.stepFrames(1, target: .trimStart)
        #expect(editor.document.trims["v1"] == Clip.range(300, 4000), "to the next frame of the movie")
        editor.stepFrames(-1, target: .trimStart)
        editor.stepFrames(-1, target: .trimStart)
        #expect(editor.document.trims["v1"] == Clip.range(100, 4000))
        editor.stepFrames(-1, target: .trimEnd)
        #expect(editor.document.trims["v1"] == Clip.range(100, 3900))
    }

    // MARK: Range ends

    @Test func rangeEndStepsMoveTheEndAndThePlayhead() {
        var editor = Self.editor()
        editor.setRangeEnd(.rangeEnd, toMs: 2000, for: "a1") // typed, unchanged: still the target
        #expect(editor.frameStepTarget == .rangeEnd("a1"))
        editor.arrowKey(forward: true)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2100) && editor.currentTimeMs == 2100)
        editor.arrowKey(forward: false, large: true)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 1100))
        editor.arrowKey(forward: false, large: true)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(100, 100), "an end before the start drags it along")
        #expect(editor.currentTimeMs == 100)
        editor.undo()
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2000) && !editor.canUndo, "one step")
    }

    @Test func rangeStartStepsClampToTheClipAndSwitchingEndsIsANewStep() {
        var editor = Self.editor()
        editor.beginTimelineDrag(.rangeStart)
        editor.endTimelineDrag()
        for _ in 0 ..< 3 {
            editor.arrowKey(forward: false, large: true)
        }
        #expect(editor.annotation("a1")?.timeRange == Clip.range(0, 2000), "clamped at the clip start")
        let moved7 = editor.arrowKey(forward: false)
        #expect(!moved7)
        editor.stepFrames(25, target: .rangeEnd("a1"))
        #expect(editor.annotation("a1")?.timeRange == Clip.range(0, 4000))
        let moved8 = editor.stepFrames(1, target: .rangeEnd("a1"))
        #expect(!moved8, "clamped at the clip end")
        editor.undo()
        #expect(editor.annotation("a1")?.timeRange == Clip.range(0, 2000), "the end's steps were their own undo step")
        editor.undo()
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2000))
        #expect(editor.bundle.validate().isEmpty)
    }

    @Test func aStepAfterUndoOrAnotherEditStartsANewUndoStep() {
        var editor = Self.editor()
        editor.stepFrames(-1, target: .trimEnd)
        editor.undo()
        editor.stepFrames(-1, target: .trimEnd)
        editor.stepFrames(-1, target: .trimEnd)
        editor.setNote("x", for: "a1")
        editor.stepFrames(-1, target: .trimEnd)
        #expect(editor.currentDurationMs == 3700)
        editor.undo()
        #expect(editor.currentDurationMs == 3800)
        editor.undo()
        editor.undo()
        #expect(editor.currentDurationMs == 4000 && !editor.canUndo)
    }

    @Test func stepsCancelATimelineDragAndRefuseImages() {
        var editor = Self.editor()
        editor.beginTimelineDrag(.rangeEnd)
        editor.updateTimelineDrag(toMs: 3000)
        editor.arrowKey(forward: true)
        #expect(editor.timelineDrag == nil)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2100), "the drag was abandoned, then the end stepped")
        editor.show(mediaId: "m2")
        let moved9 = editor.stepFrames(1, target: .playhead)
        #expect(!moved9)
        let moved10 = editor.stepFrames(1, target: .trimEnd)
        #expect(!moved10)
    }

    // MARK: Scripts

    @Test func scriptsPressArrowKeys() throws {
        let script = try EditorScript.parse(Data(#"""
        {"steps": [{"op": "arrow-key", "key": "left"}, {"op": "arrow-key", "key": "right", "shift": true}]}
        """#.utf8))
        #expect(script.steps == [.arrowKey(forward: false, shift: false), .arrowKey(forward: true, shift: true)])
        #expect(throws: (any Error).self) { try EditorScript.parse(Data(#"{"steps": [{"op": "arrow-key", "key": "up"}]}"#.utf8)) }
        #expect(throws: (any Error).self) { try EditorScript.parse(Data(#"{"steps": [{"op": "arrow-key"}]}"#.utf8)) }
    }
}
