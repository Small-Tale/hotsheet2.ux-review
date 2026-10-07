import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// The editor catching up with media added to or removed from the draft while it is open
/// (docs/06 §6.7). States crossed: which media is removed (the showing one, another, all), what
/// the editor is doing (idle, a selection, a gesture, a timeline drag, unsaved edits), and its
/// history (undo/redo entries on removed or kept media). Adversarial: repeated, interleaved,
/// out-of-order, and empty-then-refill sequences, and a removed id reused by a later capture.
struct EditorMediaSyncTests {
    typealias Base = AnnotationEditorTests

    static func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    /// m1, m2 (images) and m3 (a video), one rect on each, all saved.
    static func threeMedia() -> AnnotationEditor {
        var editor = Base.editor(media: [Base.media("m1"), Base.media("m2"), Base.media("m3", filename: "m3.mov", kind: .video)])
        for id in ["m1", "m2", "m3"] {
            editor.show(mediaId: id)
            Base.draw(&editor, .rect, [p(10, 10), p(200, 100)])
        }
        editor.markSaved()
        return editor
    }

    /// The draft on disk after removing `ids` (what `ReviewDraftStore.removeMedia` leaves).
    static func disk(_ editor: AnnotationEditor, without ids: Set<String>) -> ReviewBundle {
        var bundle = editor.savedDocument.bundle
        bundle.media.removeAll { ids.contains($0.id) }
        bundle.annotations.removeAll { ids.contains($0.mediaId) }
        return bundle
    }

    static func mediaIds(_ editor: AnnotationEditor) -> [String] { editor.bundle.media.map(\.id) }

    /// Nothing anywhere refers to removed media, and the bundle validates.
    static func expectClean(_ editor: AnnotationEditor, removed: Set<String>, sourceLocation: SourceLocation = #_sourceLocation) {
        let states = [editor.document, editor.savedDocument] + (editor.undoStack + editor.redoStack).map(\.document)
        for state in states {
            #expect(!state.bundle.media.contains { removed.contains($0.id) }, sourceLocation: sourceLocation)
            #expect(!state.bundle.annotations.contains { removed.contains($0.mediaId) }, sourceLocation: sourceLocation)
            #expect(removed.allSatisfy { state.crops[$0] == nil && state.trims[$0] == nil }, sourceLocation: sourceLocation)
        }
        #expect(
            removed.allSatisfy { editor.originalSizes[$0] == nil && editor.originalDurations[$0] == nil },
            sourceLocation: sourceLocation
        )
        #expect(editor.currentMediaId.map { !removed.contains($0) } ?? true, sourceLocation: sourceLocation)
        #expect(editor.selection.map { editor.annotation($0) != nil } ?? true, sourceLocation: sourceLocation)
        #expect(editor.gesture == nil && editor.timelineDrag == nil, sourceLocation: sourceLocation)
        // A review with no media left is the one thing `validate()` objects to.
        #expect(editor.bundle.media.isEmpty || editor.bundle.validate().isEmpty, sourceLocation: sourceLocation)
    }

    // MARK: Which media goes × what shows

    @Test(arguments: [
        // (showing, removed, expected showing after)
        ("m1", ["m1"], "m2"), // the showing one: the next
        ("m3", ["m3"], "m2"), // the last one: the previous
        ("m2", ["m1", "m2"], "m3"),
        ("m2", ["m1"], "m2"), // another one: stays
        ("m1", ["m3"], "m1"),
    ])
    func removalPicksWhatShows(showing: String, removed: [String], expected: String) {
        var editor = Self.threeMedia()
        editor.show(mediaId: showing)
        let changes = editor.syncMedia(with: Self.disk(editor, without: Set(removed)))
        #expect(changes == MediaChanges(removed: ["m1", "m2", "m3"].filter(removed.contains)))
        #expect(editor.currentMediaId == expected)
        #expect(!editor.isDirty) // the disk already lost it
        Self.expectClean(editor, removed: Set(removed))
    }

    @Test func removingEverythingThenRefilling() {
        var editor = Self.threeMedia()
        editor.syncMedia(with: Self.disk(editor, without: ["m1", "m2", "m3"]))
        #expect(editor.currentMediaId == nil && editor.bundle.media.isEmpty && editor.bundle.annotations.isEmpty)
        #expect(!editor.canUndo && !editor.canRedo) // every step only changed removed media
        Self.expectClean(editor, removed: ["m1", "m2", "m3"])
        Base.draw(&editor, .rect, [Self.p(0, 0), Self.p(100, 100)]) // nothing to draw on
        #expect(editor.bundle.annotations.isEmpty)

        var refill = editor.bundle
        refill.media = [Base.media("m4")]
        #expect(editor.syncMedia(with: refill) == MediaChanges(added: ["m4"]))
        #expect(editor.currentMediaId == "m4")
        Base.draw(&editor, .rect, [Self.p(0, 0), Self.p(100, 100)])
        #expect(editor.bundle.annotations.map(\.mediaId) == ["m4"])
        // Nothing refers to the removed annotations any more, so numbering starts over.
        #expect(editor.bundle.annotations.map(\.id) == ["a1"])
    }

    // MARK: What the editor is doing

    @Test func selectionOnRemovedMediaClearsAndOnKeptMediaStays() {
        var editor = Self.threeMedia()
        editor.select("a2") // on m2
        editor.syncMedia(with: Self.disk(editor, without: ["m1"]))
        #expect(editor.selection == "a2" && editor.currentMediaId == "m2")

        editor.syncMedia(with: Self.disk(editor, without: ["m1", "m2"]))
        #expect(editor.selection == nil && editor.currentMediaId == "m3")
    }

    @Test func aGestureIsCancelledWhicheverMediaIsRemoved() {
        for removed in ["m1", "m2"] {
            var editor = Self.threeMedia()
            editor.show(mediaId: "m1")
            editor.setTool(.rect)
            editor.beginGesture(at: Self.p(300, 300))
            editor.updateGesture(to: Self.p(400, 400))
            editor.syncMedia(with: Self.disk(editor, without: [removed]))
            #expect(editor.gesture == nil)
            editor.endGesture() // the release that follows does nothing
            #expect(editor.bundle.annotations.count == 2)
            Self.expectClean(editor, removed: [removed])
        }
    }

    @Test func aTimelineDragOnTheRemovedVideoIsCancelled() {
        var editor = Self.threeMedia()
        editor.select("a3") // on the video
        let ranged = editor.setTimeRange(TimeRange(startMs: 500, endMs: 1500), for: "a3")
        let dragging = editor.beginTimelineDrag(.rangeEnd)
        #expect(ranged && dragging)
        editor.updateTimelineDrag(toMs: 3000)
        editor.syncMedia(with: Self.disk(editor, without: ["m3"]))
        Self.expectClean(editor, removed: ["m3"])
        #expect(editor.currentTimeMs == 0)
        editor.endTimelineDrag()
        #expect(editor.bundle.annotations.map(\.id) == ["a1", "a2"])
    }

    @Test func unsavedEditsToKeptMediaSurvive() {
        var editor = Self.threeMedia()
        editor.setNote("Keep me", for: "a2")
        editor.show(mediaId: "m1")
        _ = editor.crop(to: CGRect(x: 0, y: 0, width: 500, height: 250))
        editor.syncMedia(with: Self.disk(editor, without: ["m1"]))
        #expect(editor.annotation("a2")?.note == "Keep me")
        #expect(editor.isDirty) // the note is still unsaved
        Self.expectClean(editor, removed: ["m1"])
        editor.undo() // the crop step is gone; this undoes the note
        #expect(editor.annotation("a2")?.note == "")
        #expect(Self.mediaIds(editor) == ["m2", "m3"])
    }

    @Test func trimsOfRemovedVideosLeaveEveryState() {
        var editor = Self.threeMedia()
        editor.show(mediaId: "m3")
        let trimmed = editor.trim(to: TimeRange(startMs: 500, endMs: 3000))
        #expect(trimmed)
        editor.markSaved()
        editor.syncMedia(with: Self.disk(editor, without: ["m3"]))
        Self.expectClean(editor, removed: ["m3"])
    }

    // MARK: History

    @Test func undoNeverBringsARemovedCaptureOrItsAnnotationsBack() {
        var editor = Self.threeMedia()
        editor.syncMedia(with: Self.disk(editor, without: ["m2"]))
        // History was [∅, a1, a1+a2] → [∅, a1, a1]: the step that drew a2 is gone.
        var seen: [[String]] = [editor.bundle.annotations.map(\.id)]
        while editor.canUndo {
            editor.undo()
            seen.append(editor.bundle.annotations.map(\.id))
            #expect(Self.mediaIds(editor) == ["m1", "m3"])
        }
        #expect(seen == [["a1", "a3"], ["a1"], []])
        while editor.canRedo {
            editor.redo()
        }
        #expect(editor.bundle.annotations.map(\.id) == ["a1", "a3"])
        Self.expectClean(editor, removed: ["m2"])
    }

    @Test func redoEntriesOnRemovedMediaAreDropped() {
        var editor = Self.threeMedia()
        editor.undo() // a3 (m3) to redo
        editor.undo() // a2 (m2) to redo
        editor.syncMedia(with: Self.disk(editor, without: ["m2"]))
        #expect(editor.canRedo)
        editor.redo()
        #expect(editor.bundle.annotations.map(\.id) == ["a1", "a3"])
        #expect(!editor.canRedo)
        Self.expectClean(editor, removed: ["m2"])
    }

    // MARK: Adversarial sequences

    @Test func syncIsIdempotentAndIgnoresUnknownIds() {
        var editor = Self.threeMedia()
        let disk = Self.disk(editor, without: ["m2"])
        #expect(editor.syncMedia(with: disk).removed == ["m2"])
        let after = editor
        #expect(editor.syncMedia(with: disk).isEmpty)
        #expect(editor.dropMedia(["m2", "nope"]).isEmpty)
        #expect(editor.document == after.document && editor.undoStack == after.undoStack)
    }

    @Test func aRemovedIdAndFileNameReusedByALaterCaptureIsARemovalPlusAnAddition() {
        var editor = Self.threeMedia()
        var disk = Self.disk(editor, without: ["m3"])
        var again = Base.media("m3", filename: "m3.mov", kind: .video)
        again.capturedAt = Date(timeIntervalSince1970: 60)
        disk.media.append(again)
        #expect(editor.syncMedia(with: disk) == MediaChanges(added: ["m3"], removed: ["m3"]))
        #expect(editor.annotations(on: "m3").isEmpty)
    }

    @Test func aRemovedIdReusedByALaterCaptureIsARemovalPlusAnAddition() {
        var editor = Self.threeMedia()
        editor.show(mediaId: "m3")
        var disk = Self.disk(editor, without: ["m3"])
        disk.media.append(Base.media("m3", filename: "capture-4.png")) // the next capture reuses m3
        let changes = editor.syncMedia(with: disk)
        #expect(changes == MediaChanges(added: ["m3"], removed: ["m3"]))
        #expect(editor.media("m3")?.filename == "capture-4.png")
        #expect(editor.annotations(on: "m3").isEmpty) // the old video's rect left with it
        #expect(editor.originalDurations["m3"] == nil && editor.originalSizes["m3"]?.width == 1000)
        #expect(editor.bundle.validate().isEmpty)
    }

    @Test func interleavedAddsAndRemovalsKeepEditorOrder() {
        var editor = Self.threeMedia()
        var disk = Self.disk(editor, without: ["m1"])
        disk.media.append(Base.media("m4"))
        editor.syncMedia(with: disk)
        #expect(Self.mediaIds(editor) == ["m2", "m3", "m4"])
        editor.show(mediaId: "m4")
        Base.draw(&editor, .insertion, [Self.p(5, 5)])
        disk = editor.bundle
        disk.media.removeAll { $0.id == "m4" }
        disk.annotations.removeAll { $0.mediaId == "m4" }
        disk.media.append(Base.media("m5"))
        #expect(editor.syncMedia(with: disk) == MediaChanges(added: ["m5"], removed: ["m4"]))
        #expect(Self.mediaIds(editor) == ["m2", "m3", "m5"])
        #expect(editor.currentMediaId == "m3") // m4 was last before m5 arrived: the previous
        Self.expectClean(editor, removed: ["m1", "m4"])
        // Undo walks back over kept media only.
        while editor.canUndo {
            editor.undo()
        }
        #expect(Self.mediaIds(editor) == ["m2", "m3", "m5"] && editor.bundle.annotations.isEmpty)
    }
}
