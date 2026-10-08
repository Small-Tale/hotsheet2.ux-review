import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// Video time in the editor state machine: the playhead (navigation), annotation time ranges and
/// trims (undoable edits). States: untrimmed / trimmed / trimmed twice; annotation with no range,
/// a range, an instant; selection visible / hidden at the playhead. Sequences cross those with
/// undo, redo, reset, and media switches. The clip is 4000 ms, 1000 × 500 px.
struct VideoTimeTests {
    typealias Fixture = AnnotationEditorTests

    static func clipEditor(annotations: [Annotation] = [], extraImage: Bool = false) -> AnnotationEditor {
        var media = [Fixture.media("v1", kind: .video)]
        if extraImage { media.append(Fixture.media("m2")) }
        return Fixture.editor(media: media, annotations: annotations)
    }

    static func box(_ id: String, _ range: TimeRange?, x: Int = 1000) -> Annotation {
        Annotation(id: id, mediaId: "v1", shape: .rect(NormRect(x: x, y: 1000, width: 2000, height: 2000)), note: id, timeRange: range)
    }

    static func range(_ start: Int, _ end: Int) -> TimeRange { TimeRange(startMs: start, endMs: end) }

    // MARK: Playhead and visibility

    @Test func annotationsShowOnlyInsideTheirRangeBothEndsInclusive() {
        var editor = Self.clipEditor(annotations: [
            Self.box("a1", nil), Self.box("a2", Self.range(1000, 2000)), Self.box("a3", Self.range(3000, 3000)),
        ])
        func visible() -> [String] { editor.visibleAnnotations(on: "v1").map(\.id) }
        #expect(visible() == ["a1"])
        editor.setCurrentTime(1000)
        #expect(visible() == ["a1", "a2"])
        editor.setCurrentTime(2000)
        #expect(visible() == ["a1", "a2"])
        editor.setCurrentTime(2001)
        #expect(visible() == ["a1"])
        editor.setCurrentTime(3000)
        #expect(visible() == ["a1", "a3"], "an instant shows exactly at its time")
    }

    @Test func playheadClampsStepsAndIsNotUndoable() {
        var editor = Self.clipEditor()
        editor.setCurrentTime(-50)
        #expect(editor.currentTimeMs == 0)
        editor.setCurrentTime(99999)
        #expect(editor.currentTimeMs == 4000)
        editor.stepTime(forward: false)
        #expect(editor.currentTimeMs == 3900)
        editor.stepTime(forward: false, large: true)
        #expect(editor.currentTimeMs == 2900)
        #expect(!editor.canUndo && !editor.isDirty)
    }

    @Test func imagesHaveNoPlayheadAndRefuseRangesAndTrims() {
        var editor = Fixture.editor(annotations: [Annotation(id: "a1", mediaId: "m1", shape: .insertion(NormPoint(x: 5, y: 5)), note: "")])
        editor.setCurrentTime(500)
        #expect(editor.currentTimeMs == 0 && editor.currentDurationMs == nil)
        let done1 = editor.setTimeRange(Self.range(0, 10), for: "a1")
        #expect(!done1)
        let done2 = editor.trim(to: Self.range(0, 10))
        #expect(!done2)
        #expect(editor.message == "Only videos can be trimmed.")
        let done3 = editor.trimStartToPlayhead()
        #expect(!done3)
        #expect(!editor.canUndo)
    }

    @Test func showingOtherMediaResetsThePlayhead() {
        var editor = Self.clipEditor(extraImage: true)
        editor.setCurrentTime(1500)
        editor.show(mediaId: "m2")
        #expect(editor.currentTimeMs == 0)
        editor.show(mediaId: "v1")
        #expect(editor.currentTimeMs == 0)
    }

    @Test func selectingAHiddenAnnotationMovesThePlayheadToIt() {
        var editor = Self.clipEditor(annotations: [Self.box("a1", Self.range(2500, 3000)), Self.box("a2", nil)])
        editor.setCurrentTime(100)
        editor.select("a1")
        #expect(editor.currentTimeMs == 2500)
        editor.setCurrentTime(2800)
        editor.select("a1")
        #expect(editor.currentTimeMs == 2800, "already visible: the playhead stays")
        editor.select("a2")
        #expect(editor.currentTimeMs == 2800)
        editor.setCurrentTime(0)
        editor.selectNext()
        #expect(editor.selection == "a1" && editor.currentTimeMs == 2500, "Tab also reveals")
    }

    @Test func hiddenAnnotationsCanNotBeClickedOrResized() {
        var editor = Self.clipEditor(annotations: [Self.box("a1", Self.range(2000, 3000))])
        // a1 covers pixels 100…300 × 50…150.
        editor.beginGesture(at: Fixture.p(200, 100))
        editor.endGesture()
        #expect(editor.selection == nil, "hidden at 0 ms")
        editor.select("a1")
        editor.setCurrentTime(0)
        editor.beginGesture(at: Fixture.p(100, 50)) // its corner handle
        #expect(editor.gesture == nil && editor.selection == nil, "a hidden selection has no handles")
        editor.setCurrentTime(2500)
        editor.beginGesture(at: Fixture.p(200, 100))
        #expect(editor.selection == "a1")
        editor.cancelGesture()
    }

    @Test func newShapesOnVideoCoverTheWholeClip() {
        var editor = Self.clipEditor()
        editor.setCurrentTime(1200)
        Fixture.draw(&editor, .rect, [Fixture.p(10, 10), Fixture.p(200, 100)])
        #expect(editor.selectedAnnotation?.timeRange == nil)
        #expect(editor.visibleAnnotations(on: "v1").count == 1)
    }

    // MARK: Time ranges

    @Test func setTimeRangeClampsSwapsAndIsOneUndoStep() {
        var editor = Self.clipEditor(annotations: [Self.box("a1", nil)])
        let done4 = editor.setTimeRange(Self.range(3000, -10), for: "a1")
        #expect(done4)
        #expect(editor.annotation("a1")?.timeRange == Self.range(0, 3000))
        let done5 = editor.setTimeRange(Self.range(3500, 9000), for: "a1")
        #expect(done5)
        #expect(editor.annotation("a1")?.timeRange == Self.range(3500, 4000))
        let done6 = editor.setTimeRange(Self.range(3500, 9000), for: "a1")
        #expect(!done6, "no change records nothing")
        editor.undo()
        #expect(editor.annotation("a1")?.timeRange == Self.range(0, 3000))
        editor.undo()
        #expect(editor.annotation("a1")?.timeRange == nil)
        editor.redo()
        editor.redo()
        #expect(editor.annotation("a1")?.timeRange == Self.range(3500, 4000))
        let done7 = editor.setTimeRange(nil, for: "a1")
        #expect(done7)
        #expect(editor.annotation("a1")?.timeRange == nil)
        #expect(editor.bundle.validate().isEmpty)
    }

    @Test func duplicateKeepsTheTimeRange() {
        var editor = Self.clipEditor(annotations: [Self.box("a1", Self.range(500, 900))])
        editor.select("a1")
        editor.duplicateSelection()
        #expect(editor.selectedAnnotation?.timeRange == Self.range(500, 900))
    }

    // MARK: Trimming

    @Test func trimsComposeAndResetMapsRangesBack() {
        var editor = Self.clipEditor(annotations: [Self.box("a1", Self.range(1500, 2500))])
        editor.setCurrentTime(1000)
        let first = editor.trimStartToPlayhead() // keeps 1000…4000
        #expect(first)
        #expect(editor.currentTimeMs == 0 && editor.currentMedia?.durationMs == 3000)
        editor.setCurrentTime(2000)
        let second = editor.trimEndToPlayhead() // keeps 0…2000 of that, i.e. 1000…3000
        #expect(second)
        #expect(editor.document.trims["v1"] == Self.range(1000, 3000))
        #expect(editor.annotation("a1")?.timeRange == Self.range(500, 1500))
        #expect(editor.canRestoreOriginal)
        editor.setCurrentTime(700)

        let done9 = editor.restoreOriginal()

        #expect(done9)
        #expect(editor.document.trims.isEmpty && editor.currentMedia?.durationMs == 4000)
        #expect(editor.annotation("a1")?.timeRange == Self.range(1500, 2500))
        #expect(editor.currentTimeMs == 1700, "the playhead stays on the same frame")
        let again = editor.resetTrim()
        #expect(!editor.canRestoreOriginal && !again)
        editor.undo()
        #expect(editor.document.trims["v1"] == Self.range(1000, 3000))
    }

    @Test func refusesTooShortFullLengthAndOutOfRangeTrims() {
        var editor = Self.clipEditor()
        let done10 = editor.trim(to: Self.range(1000, 1099))
        #expect(!done10)
        #expect(editor.message == "A trimmed video must be at least 100 ms long.")
        let done11 = editor.trim(to: Self.range(0, 4000))
        #expect(!done11, "the whole clip changes nothing")
        let done12 = editor.trim(to: Self.range(-500, 9000))
        #expect(!done12, "clamped to the whole clip")
        let done13 = editor.trim(to: Self.range(3900, 9000))
        #expect(done13)
        #expect(editor.currentMedia?.durationMs == 100)
        editor.setCurrentTime(0)
        let done14 = editor.trimEndToPlayhead()
        #expect(!done14, "a zero-length clip is refused")
        #expect(editor.undoStackCount == 1)
    }

    @Test func trimmingAgainAfterUndoClearsRedoAndKeepsIdsUnique() {
        var editor = Self.clipEditor(annotations: [Self.box("a1", Self.range(0, 100))])
        let done15 = editor.trim(to: Self.range(2000, 4000))
        #expect(done15)
        #expect(editor.annotation("a1").map(editor.isOutsideEdit) == true)
        #expect(editor.submissionBundle.annotations.isEmpty)
        editor.undo()
        let done16 = editor.trim(to: Self.range(0, 1000))
        #expect(done16)
        #expect(!editor.canRedo)
        #expect(editor.annotation("a1")?.timeRange == Self.range(0, 100))
        Fixture.draw(&editor, .rect, [Fixture.p(10, 10), Fixture.p(200, 100)])
        #expect(editor.selection == "a2")
    }

    @Test func emptyThenRefillRangesAcrossRepeatedTrimsAndResets() {
        var editor = Self.clipEditor(annotations: [Self.box("a1", Self.range(3000, 3500))])
        for _ in 0 ..< 3 {
            let done17 = editor.trim(to: Self.range(0, 2000))
            #expect(done17)
            #expect(editor.annotation("a1").map(editor.isOutsideEdit) == true)
            #expect(editor.submissionBundle.annotations.isEmpty)
            editor.undo()
            #expect(editor.annotation("a1")?.timeRange == Self.range(3000, 3500))
            let done18 = editor.trim(to: Self.range(2500, 4000))
            #expect(done18)
            #expect(editor.annotation("a1")?.timeRange == Self.range(500, 1000))
            let done19 = editor.resetTrim()
            #expect(done19)
            #expect(editor.annotation("a1")?.timeRange == Self.range(3000, 3500))
        }
        #expect(editor.bundle.validate().isEmpty)
    }

    @Test func priorTrimsStartAppliedAndResetToTheOriginal() {
        let item = MediaItem(
            id: "v1", filename: "v1.mov", kind: .video, pixelWidth: 1000, pixelHeight: 500, durationMs: 1500,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        var editor = AnnotationEditor(
            bundle: TestSupport.bundle(media: [item], annotations: [Self.box("a1", Self.range(100, 200))]),
            trims: ["v1": PriorTrim(originalDurationMs: 4000, trim: Self.range(1000, 2500))]
        )
        #expect(!editor.isDirty && editor.canRestoreOriginal)
        #expect(editor.document.trims["v1"] == Self.range(1000, 2500))
        let done20 = editor.restoreOriginal()
        #expect(done20)
        #expect(editor.currentMedia?.durationMs == 4000)
        #expect(editor.annotation("a1")?.timeRange == Self.range(1100, 1200))

        let full = AnnotationEditor(
            bundle: TestSupport.bundle(media: [item]), trims: ["v1": PriorTrim(originalDurationMs: 1500, trim: Self.range(0, 1500))]
        )
        #expect(full.document.trims.isEmpty, "a full-length record is no trim")
    }

    @Test func undoAcrossTrimAndMediaSwitchRestoresTheVideoAndItsPlayhead() {
        var editor = Self.clipEditor(extraImage: true)
        editor.setCurrentTime(3000)
        let done21 = editor.trim(to: Self.range(0, 3500))
        #expect(done21)
        editor.show(mediaId: "m2")
        editor.undo()
        #expect(editor.currentMediaId == "v1" && editor.currentTimeMs == 3000)
        editor.redo()
        #expect(editor.currentMediaId == "m2", "redo returns to the media showing when undo ran")
        #expect(editor.media("v1")?.durationMs == 3500)
    }

    @Test func accessibilityLabelReadsTheRange() {
        let editor = Self.clipEditor(annotations: [Self.box("a1", Self.range(1000, 2500))])
        #expect(editor.accessibilityLabel(for: "a1") == "Annotation 1: Rectangle, comment, shows 0:01.00–0:02.50. a1")
    }

    @Test func timeFormats() {
        #expect(TimeFormat.clock(0) == "0:00.00")
        #expect(TimeFormat.clock(61239) == "1:01.23")
        #expect(TimeFormat.seconds(4250) == "4.2 s" || TimeFormat.seconds(4250) == "4.3 s")
        #expect(TimeFormat.range(nil) == "Whole clip")
        #expect(TimeFormat.range(Self.range(500, 500)) == "0:00.50")
        #expect(TimeFormat.range(Self.range(500, 1500)) == "0:00.50–0:01.50")
    }

    @Test func originalsIndexTrimRecordsRoundTripAndAreTrustedOnlyWhenConsistent() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var index = OriginalsIndex()
        index.trims["clip.mov"] = TrimRecord(startMs: 1000, endMs: 2500, originalDurationMs: 4000)
        try index.save(to: dir)
        let loaded = OriginalsIndex.load(from: dir)
        #expect(loaded == index)
        #expect(
            loaded.priorTrim(filename: "clip.mov", originalExists: true, currentDurationMs: 1500)
                == PriorTrim(originalDurationMs: 4000, trim: Self.range(1000, 2500))
        )
        #expect(loaded.priorTrim(filename: "clip.mov", originalExists: false, currentDurationMs: 1500) == nil)
        #expect(loaded.priorTrim(filename: "clip.mov", originalExists: true, currentDurationMs: 1600) == nil)
        #expect(loaded.priorTrim(filename: "other.mov", originalExists: true, currentDurationMs: 1500) == nil)
        index.trims["clip.mov"] = TrimRecord(startMs: 3000, endMs: 4500, originalDurationMs: 4000)
        #expect(index.priorTrim(filename: "clip.mov", originalExists: true, currentDurationMs: 1500) == nil, "past the original")

        // An index written before trims existed still loads, and crops-only indexes omit the key.
        try Data(#"{"crops": {}, "version": 1}"#.utf8).write(to: OriginalsIndex.url(in: dir))
        #expect(OriginalsIndex.load(from: dir).trims.isEmpty)
        try OriginalsIndex(crops: [:]).save(to: dir)
        #expect(try !String(contentsOf: OriginalsIndex.url(in: dir), encoding: .utf8).contains("trims"))
    }
}

extension AnnotationEditor {
    var undoStackCount: Int { undoStack.count }
}
