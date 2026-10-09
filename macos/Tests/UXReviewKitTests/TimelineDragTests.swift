import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// Dragging range ends and trim handles on the timeline, typing exact times, and the timeline's
/// hit rules (docs/06-annotation-editor.md §6.10). States: no drag / range drag / trim drag;
/// transitions: begin, update (inside, past the other end, beyond the clip), end, cancel, and
/// interruptions (undo, redo, playhead, media switch, a new drag). The clip is 4000 ms.
struct TimelineDragTests {
    typealias Clip = VideoTimeTests

    static func ranged(_ range: TimeRange? = Clip.range(1000, 2000)) -> AnnotationEditor {
        var editor = Clip.clipEditor(annotations: [Clip.box("a1", range), Clip.box("a2", Clip.range(3000, 3500))], extraImage: true)
        editor.select("a1")
        return editor
    }

    // MARK: Range ends

    @Test func draggingAnEndEditsLiveAndCommitsOneUndoStep() {
        var editor = Self.ranged()
        let done1 = editor.beginTimelineDrag(.rangeEnd)
        #expect(done1)
        for time in [2200, 2600, 3100] {
            editor.updateTimelineDrag(toMs: time)
            #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, time))
            #expect(editor.currentTimeMs == time, "the playhead follows the handle")
        }
        #expect(!editor.canUndo, "nothing is committed mid-drag")
        editor.endTimelineDrag()
        #expect(editor.timelineDrag == nil)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 3100))
        #expect(editor.currentTimeMs == 3100)
        editor.undo()
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2000))
        #expect(!editor.canUndo, "exactly one step")
        editor.redo()
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 3100))
    }

    @Test func draggingPastTheOtherEndSwapsAndClampsToTheClip() {
        var editor = Self.ranged()
        editor.beginTimelineDrag(.rangeStart)
        editor.updateTimelineDrag(toMs: 2500)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(2000, 2500), "start past end: the end stays, the pointer is the new end")
        editor.updateTimelineDrag(toMs: 2000)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(2000, 2000), "an instant on the way")
        editor.updateTimelineDrag(toMs: -300)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(0, 2000))
        editor.updateTimelineDrag(toMs: 99999)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(2000, 4000))
        #expect(editor.currentTimeMs == 4000)
        editor.endTimelineDrag()
        #expect(editor.bundle.validate().isEmpty)
    }

    @Test func anInstantCanBeDraggedOpenEitherWay() {
        var editor = Self.ranged(Clip.range(1500, 1500))
        editor.beginTimelineDrag(.rangeStart)
        editor.updateTimelineDrag(toMs: 900)
        editor.endTimelineDrag()
        #expect(editor.annotation("a1")?.timeRange == Clip.range(900, 1500))
        editor.beginTimelineDrag(.rangeEnd)
        editor.updateTimelineDrag(toMs: 600)
        editor.endTimelineDrag()
        #expect(editor.annotation("a1")?.timeRange == Clip.range(600, 900))
    }

    @Test func aDragThatEndsWhereItStartedRecordsNothing() {
        var editor = Self.ranged()
        editor.beginTimelineDrag(.rangeEnd)
        editor.updateTimelineDrag(toMs: 3000)
        editor.updateTimelineDrag(toMs: 2000)
        editor.endTimelineDrag()
        #expect(!editor.canUndo && !editor.isDirty)
    }

    @Test func rangeHandlesNeedASelectedRangeOnTheCurrentVideo() {
        var whole = Self.ranged(nil)
        let done2 = whole.beginTimelineDrag(.rangeStart)
        #expect(!done2, "whole clip: no handles")
        var none = Self.ranged()
        none.select(nil)
        let done3 = none.beginTimelineDrag(.rangeEnd)
        #expect(!done3)
        var image = Self.ranged()
        image.show(mediaId: "m2")
        let done4 = image.beginTimelineDrag(.rangeEnd)
        #expect(!done4)
        let done5 = image.beginTimelineDrag(.trimStart)
        #expect(!done5, "images have no timeline")
        #expect(image.timelineDrag == nil)
    }

    // MARK: Cancel and interruptions

    @Test func cancelRestoresTheRangeAndThePlayhead() {
        var editor = Self.ranged()
        editor.setCurrentTime(1200)
        editor.beginTimelineDrag(.rangeStart)
        editor.updateTimelineDrag(toMs: 300)
        editor.cancelTimelineDrag()
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2000))
        #expect(editor.currentTimeMs == 1200)
        #expect(!editor.canUndo && !editor.isDirty)
        editor.cancelTimelineDrag() // repeated: nothing to do
        #expect(editor.timelineDrag == nil)
    }

    @Test func interruptionsCancelTheDragFirst() {
        // Each interruption mid-drag must leave the pre-drag range, then do its own thing.
        let interruptions: [(String, (inout AnnotationEditor) -> Void)] = [
            ("undo", { $0.undo() }),
            ("redo", { $0.redo() }),
            ("playhead", { $0.setCurrentTime(100) }),
            ("step", { $0.stepTime(forward: true) }),
            ("media", { $0.show(mediaId: "m2") }),
            ("select", { $0.select("a2") }),
            ("canvas gesture", { $0.beginGesture(at: CGPoint(x: 5, y: 5)) }),
            ("another drag", { _ = $0.beginTimelineDrag(.trimEnd) }),
        ]
        for (name, interrupt) in interruptions {
            var editor = Self.ranged()
            editor.beginTimelineDrag(.rangeEnd)
            editor.updateTimelineDrag(toMs: 3900)
            interrupt(&editor)
            #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2000), "\(name)")
            #expect(!editor.canUndo, "\(name): nothing committed")
            editor.endTimelineDrag() // a stale release does nothing for a cancelled drag
            #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2000), "\(name): stale release")
        }
    }

    @Test func undoAfterACommittedDragThenRedragRefillsHistory() {
        var editor = Self.ranged()
        for target in [2500, 3000, 3500] {
            editor.beginTimelineDrag(.rangeEnd)
            editor.updateTimelineDrag(toMs: target)
            editor.endTimelineDrag()
        }
        editor.undo()
        editor.undo()
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2500))
        #expect(editor.canRedo)
        editor.beginTimelineDrag(.rangeStart)
        editor.updateTimelineDrag(toMs: 100)
        editor.endTimelineDrag()
        #expect(!editor.canRedo, "a new drag clears redo")
        #expect(editor.annotation("a1")?.timeRange == Clip.range(100, 2500))
        editor.undo()
        editor.undo()
        editor.undo()
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2000))
    }

    // MARK: Trim handles

    @Test func trimDragsPreviewThenTrimOnRelease() {
        var editor = Self.ranged()
        let done6 = editor.beginTimelineDrag(.trimStart)
        #expect(done6)
        editor.updateTimelineDrag(toMs: 1500)
        #expect(editor.timelineDrag?.pendingTrim == Clip.range(1500, 4000))
        #expect(editor.currentDurationMs == 4000, "nothing trimmed mid-drag")
        #expect(editor.currentTimeMs == 1500)
        editor.endTimelineDrag()
        #expect(editor.currentDurationMs == 2500)
        #expect(editor.currentTimeMs == 0, "the playhead stays on the cut")
        #expect(editor.annotation("a1")?.timeRange == Clip.range(-500, 500), "shifted exactly (HS2-71SSJG)")
        #expect(editor.submissionBundle.annotations.first { $0.id == "a1" }?.timeRange == Clip.range(0, 500))
        #expect(editor.message?.hasPrefix("Trimmed to 2.5 s.") == true)
        editor.undo()
        #expect(editor.currentDurationMs == 4000)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 2000))
        #expect(!editor.canUndo, "one step")
    }

    @Test func trimEndDragAndTheMinimumLength() {
        var editor = Self.ranged()
        editor.beginTimelineDrag(.trimEnd)
        editor.updateTimelineDrag(toMs: 20)
        #expect(editor.timelineDrag?.pendingTrim == Clip.range(0, AnnotationEditor.minimumTrimMs), "never shorter than the minimum")
        editor.updateTimelineDrag(toMs: 2500)
        editor.endTimelineDrag()
        #expect(editor.currentDurationMs == 2500)
        #expect(editor.currentTimeMs == 2500)
        #expect(editor.annotation("a2").map(editor.isOutsideEdit) == true, "outside the trim: hidden, not removed")
        editor.beginTimelineDrag(.trimStart)
        editor.updateTimelineDrag(toMs: 99999)
        #expect(editor.timelineDrag?.pendingTrim == Clip.range(2500 - AnnotationEditor.minimumTrimMs, 2500))
        editor.cancelTimelineDrag()
        #expect(editor.currentDurationMs == 2500)
        #expect(editor.currentTimeMs == 2500)
    }

    @Test func aTrimDragBackToTheEndChangesNothing() {
        var editor = Self.ranged()
        editor.setCurrentTime(700)
        editor.beginTimelineDrag(.trimEnd)
        editor.updateTimelineDrag(toMs: 1000)
        editor.updateTimelineDrag(toMs: 4000)
        editor.endTimelineDrag()
        #expect(editor.currentDurationMs == 4000 && !editor.canUndo)
        #expect(editor.currentTimeMs == 4000, "the playhead stays where the handle was released")
    }

    // MARK: Typed ends

    @Test func typedEndsDragTheOtherEndAlong() {
        var editor = Self.ranged()
        let done7 = editor.setRangeEnd(.rangeStart, toMs: 1500, for: "a1")
        #expect(done7)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1500, 2000))
        let done8 = editor.setRangeEnd(.rangeStart, toMs: 2600, for: "a1")
        #expect(done8)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(2600, 2600))
        let done9 = editor.setRangeEnd(.rangeEnd, toMs: 900, for: "a1")
        #expect(done9)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(900, 900))
        let done10 = editor.setRangeEnd(.rangeEnd, toMs: 99999, for: "a1")
        #expect(done10)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(900, 4000))
        let done11 = editor.setRangeEnd(.rangeEnd, toMs: 4000, for: "a1")
        #expect(!done11, "unchanged")
        let done12 = editor.setRangeEnd(.trimEnd, toMs: 100, for: "a1")
        #expect(!done12)
        var whole = Self.ranged(nil)
        let done13 = whole.setRangeEnd(.rangeStart, toMs: 100, for: "a1")
        #expect(!done13)
    }

    @Test(arguments: [
        ("0:01.50", 1500), ("1:02.5", 62500), ("1.5", 1500), ("1.5 s", 1500), ("2s", 2000), ("1500 ms", 1500),
        ("1500ms", 1500), ("0", 0), (" 0:00.04 ", 40), ("1:00:02", 3_602_000), ("12", 12000),
    ])
    func parsesTypedTimes(text: String, millis: Int) {
        #expect(TimeFormat.parse(text) == millis)
    }

    @Test(arguments: ["", "abc", "-1", "1:75", "1::2", ":30", "1.2.3", "1:2:3:4", "1.5 m", "-5 ms", "1e3"])
    func rejectsWhatIsNotATime(text: String) {
        #expect(TimeFormat.parse(text) == nil)
    }

    @Test func clockRoundTripsThroughParse() {
        for millis in [0, 10, 990, 1000, 61500, 599_990] {
            #expect(TimeFormat.parse(TimeFormat.clock(millis)) == millis)
        }
    }

    // MARK: Hit testing

    @Test func hitTestingPicksRangeEndsThenTrimHandlesElseScrub() {
        let range = Clip.range(1000, 2000) // x 100…200 on a 400 pt track of 4000 ms
        func hit(_ x: CGFloat, _ y: CGFloat, _ selected: TimeRange? = range, trim: TimeRange? = Clip.range(0, 4000)) -> TimelineHandle? {
            TimelineHitTest.handle(x: x, y: y, width: 400, durationMs: 4000, selectedRange: selected, trim: trim)
        }
        #expect(hit(102, 55) == .rangeStart)
        #expect(hit(196, 55) == .rangeEnd)
        #expect(hit(150, 55) == nil, "the middle of a range scrubs")
        #expect(hit(102, 5) == nil, "range handles live in the lane")
        #expect(hit(3, 5) == .trimStart)
        #expect(hit(398, 5) == .trimEnd)
        #expect(hit(3, 55, nil) == nil, "trim handles live on the scrubber row")
        #expect(hit(250, 5) == nil)
        #expect(hit(98, 55, Clip.range(1000, 1000)) == .rangeStart, "an instant: left of it grabs the start")
        #expect(hit(101, 55, Clip.range(1000, 1000)) == .rangeEnd)
        #expect(hit(2, 55, Clip.range(0, 4000)) == .rangeStart, "a full range still has handles at the ends")
        #expect(TimelineHitTest.handle(x: 3, y: 5, width: 400, durationMs: 0, selectedRange: nil) == nil)
        // HS2-ECE7WY: trim handles only in Trim mode, at its range's ends; elsewhere the row scrubs.
        #expect(hit(3, 5, trim: nil) == nil && hit(398, 5, trim: nil) == nil)
        #expect(hit(102, 5, trim: Clip.range(1000, 3000)) == .trimStart)
        #expect(hit(296, 5, trim: Clip.range(1000, 3000)) == .trimEnd)
        #expect(hit(3, 5, trim: Clip.range(1000, 3000)) == nil)
    }

    // MARK: Scripts

    @Test func scriptsDragHandles() throws {
        let script = try EditorScript.parse(Data(#"""
        {"steps": [
          {"op": "timeline-drag", "handle": "range-end", "ms": [2500, 3200]},
          {"op": "cancel-timeline-drag", "handle": "range-start", "ms": [0]},
          {"op": "timeline-drag", "handle": "trim-start", "ms": [400, 500]}
        ]}
        """#.utf8))
        #expect(script.steps[0] == .timelineDrag(.rangeEnd, [2500, 3200], cancel: false))
        #expect(script.steps[1] == .timelineDrag(.rangeStart, [0], cancel: true))
        #expect(throws: (any Error).self) {
            try EditorScript.parse(Data(#"{"steps": [{"op": "timeline-drag", "handle": "middle", "ms": [1]}]}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try EditorScript.parse(Data(#"{"steps": [{"op": "timeline-drag", "handle": "trim-end", "ms": []}]}"#.utf8))
        }
    }
}
