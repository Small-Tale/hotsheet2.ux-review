import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// docs/06 §6.7 through real files: captures removed from the draft while an editor session is
/// open (HS2-2QP0GM).
extension EditorSessionTests {
    /// docs/06 §6.7: the review session removes a capture while the editor is open, with
    /// unsaved edits on it and on another capture. Saving (with or without a reload first)
    /// never writes the removed capture back.
    @Test(arguments: [false, true])
    func aCaptureRemovedWhileEditingIsNeverWrittenBack(reloadFirst: Bool) throws {
        let fixture = try Fixture()
        try fixture.store.add(fixture.capture(width: 300, height: 300))
        let session = try fixture.session()
        session.editor.show(mediaId: "m2")
        AnnotationEditorTests.draw(&session.editor, .insertion, [CGPoint(x: 5, y: 5)])
        session.editor.show(mediaId: "m1")
        AnnotationEditorTests.draw(&session.editor, .rect, [CGPoint(x: 120, y: 60), CGPoint(x: 160, y: 100)])
        let cropped = session.editor.crop(to: CGRect(x: 100, y: 50, width: 200, height: 100))
        #expect(cropped)
        #expect(session.displayImage("m1") != nil) // the base image is cached

        try fixture.store.removeMedia("m1", from: fixture.draft.directory)
        let changes = try reloadFirst ? session.reload() : session.save()
        #expect(changes == MediaChanges(removed: ["m1"]))
        if reloadFirst { try session.save() }

        let directory = fixture.draft.directory
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("capture-1.png").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("originals/capture-1.png").path))
        let disk = try fixture.onDisk()
        #expect(disk.media.map(\.id) == ["m2"])
        #expect(disk.annotations.map(\.mediaId) == ["m2"]) // the unsaved insertion on m2 is kept
        #expect(disk.validate().isEmpty)
        #expect(session.editor.currentMediaId == "m2" && !session.editor.isDirty)
        // Undo can't bring it back, and saving after undo leaves the disk consistent.
        while session.editor.canUndo {
            session.editor.undo()
        }
        try session.save()
        #expect(try fixture.onDisk().media.map(\.id) == ["m2"])
        #expect(try fixture.onDisk().annotations.isEmpty)
    }

    /// HS2-SSM1E7: Remove from Review in the editor saves first, so unsaved work on the other
    /// capture (an annotation and a crop) reaches disk, then removes the chosen capture.
    @Test func removingFromTheEditorKeepsUnsavedWorkOnOtherCaptures() throws {
        let fixture = try Fixture()
        try fixture.store.add(fixture.capture(width: 300, height: 300))
        let session = try fixture.session()
        session.editor.show(mediaId: "m2")
        AnnotationEditorTests.draw(&session.editor, .rect, [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 120)])
        let cropped = session.editor.crop(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(cropped)
        session.editor.show(mediaId: "m1")
        AnnotationEditorTests.draw(&session.editor, .insertion, [CGPoint(x: 5, y: 5)])
        #expect(session.editor.isDirty)

        #expect(try session.removeCapture("m1") == MediaChanges(removed: ["m1"]))

        let directory = fixture.draft.directory
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("capture-1.png").path))
        let disk = try fixture.onDisk()
        #expect(disk.media.map(\.id) == ["m2"])
        // m2's unsaved crop was saved first (as a record; the file keeps its size).
        #expect(DraftEdits.load(from: directory).crops["capture-2.png"] == PixelRect(x: 0, y: 0, width: 200, height: 200))
        #expect(disk.annotations.map(\.mediaId) == ["m2"])
        #expect(disk.validate().isEmpty)
        #expect(session.editor.currentMediaId == "m2")
        #expect(!session.editor.isDirty)
        // Removing the last capture leaves an empty review the editor still shows.
        try session.removeCapture("m2")
        #expect(try fixture.onDisk().media.isEmpty)
        #expect(session.editor.currentMediaId == nil)
        #expect(throws: ReviewDraftError.unknownMedia("m2")) { try session.removeCapture("m2") }
    }

    @Test func scriptRemoveCaptureSavesBeforeRemoving() throws {
        let fixture = try Fixture()
        try fixture.store.add(fixture.capture(width: 300, height: 300))
        let steps = try JSONDecoder().decode([EditorScript.Step].self, from: Data(#"""
        [{"op": "media", "media": "m2"}, {"op": "tool", "tool": "rect"},
         {"op": "drag", "points": [[10, 10], [90, 90]]},
         {"op": "remove-capture", "media": "m1"}]
        """#.utf8))
        #expect(steps.last == .removeCapture("m1"))
        let session = try fixture.session()
        _ = try EditorScript(steps: steps).run(on: session)
        #expect(try fixture.onDisk().media.map(\.id) == ["m2"])
        #expect(try fixture.onDisk().annotations.count == 1)
    }

    /// HS2-0TQ6RP: ⌘⌫ on a multiple selection removes every selected capture at once, after
    /// saving unsaved work on the one that stays; the editor shows the nearest remaining capture.
    @Test func removingSeveralSelectedCapturesKeepsUnsavedWorkOnTheRest() throws {
        let fixture = try Fixture()
        for _ in 0 ..< 3 {
            try fixture.store.add(fixture.capture(width: 300, height: 300))
        }
        let session = try fixture.session()
        session.editor.show(mediaId: "m3")
        AnnotationEditorTests.draw(&session.editor, .rect, [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 120)])
        session.editor.show(mediaId: "m1")
        AnnotationEditorTests.draw(&session.editor, .insertion, [CGPoint(x: 5, y: 5)])
        session.editor.clickMedia("m2", .plain)
        session.editor.clickMedia("m4", .extend)
        session.editor.clickMedia("m3", .toggle)
        #expect(session.editor.selectedMediaIds == ["m2", "m4"] && session.editor.currentMediaId == "m4")
        #expect(session.editor.isDirty)
        // The thumbnail menu on a selected capture acts on the selection; on another, on it alone.
        #expect(session.editor.mediaToRemove(from: "m2") == ["m2", "m4"])
        #expect(session.editor.mediaToRemove(from: "m1") == ["m1"])

        #expect(try session.removeCaptures(session.editor.mediaToRemove()) == MediaChanges(removed: ["m2", "m4"]))

        let directory = fixture.draft.directory
        for (name, exists) in [("capture-1.png", true), ("capture-2.png", false), ("capture-3.png", true), ("capture-4.png", false)] {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) == exists, "\(name)")
        }
        let disk = try fixture.onDisk()
        #expect(disk.media.map(\.id) == ["m1", "m3"])
        #expect(disk.annotations.map(\.mediaId).sorted() == ["m1", "m3"]) // unsaved work on both kept
        #expect(disk.validate().isEmpty)
        #expect(session.editor.currentMediaId == "m3" && session.editor.selectedMediaIds == ["m3"])
        #expect(!session.editor.isDirty)
        // Undo never brings a removed capture back.
        while session.editor.canUndo {
            session.editor.undo()
        }
        #expect(session.editor.bundle.media.map(\.id) == ["m1", "m3"])

        // Removing every capture leaves the empty review, as removing the last one does.
        session.editor.clickMedia("m1", .toggle)
        #expect(session.editor.selectedMediaIds == ["m1", "m3"])
        try session.removeCaptures(session.editor.mediaToRemove())
        #expect(try fixture.onDisk().media.isEmpty)
        #expect(session.editor.currentMediaId == nil && session.editor.selectedMediaIds.isEmpty)
        #expect(try session.removeCaptures([]) == MediaChanges())
    }

    /// An unknown id removes nothing (checked before saving or removing); repeats count once.
    @Test func removingSeveralChecksEveryIdFirst() throws {
        let fixture = try Fixture()
        try fixture.store.add(fixture.capture(width: 300, height: 300))
        let session = try fixture.session()
        #expect(throws: ReviewDraftError.unknownMedia("m9")) { try session.removeCaptures(["m1", "m9"]) }
        #expect(try fixture.onDisk().media.map(\.id) == ["m1", "m2"])
        #expect(try session.removeCaptures(["m2", "m2"]) == MediaChanges(removed: ["m2"]))
    }

    /// The `--annotate` ops behind the strip's clicks and ⌘⌫.
    @Test func scriptClicksAndRemovesTheSelection() throws {
        let fixture = try Fixture()
        try fixture.store.add(fixture.capture(width: 300, height: 300))
        try fixture.store.add(fixture.capture(width: 300, height: 300))
        let steps = try JSONDecoder().decode([EditorScript.Step].self, from: Data(#"""
        [{"op": "click-media", "media": "m1"}, {"op": "click-media", "media": "m3", "modifier": "shift"},
         {"op": "click-media", "media": "m2", "modifier": "command"}, {"op": "remove-selected-captures"}]
        """#.utf8))
        #expect(steps == [
            .clickMedia("m1", .plain), .clickMedia("m3", .extend), .clickMedia("m2", .toggle), .removeSelectedCaptures,
        ])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                EditorScript.Step.self,
                from: Data(#"{"op": "click-media", "media": "m1", "modifier": "option"}"#.utf8)
            )
        }
        let session = try fixture.session()
        _ = try EditorScript(steps: steps).run(on: session)
        #expect(try fixture.onDisk().media.map(\.id) == ["m2"])
        #expect(session.editor.selectedMediaIds == ["m2"])
        // Unknown media fails its step.
        #expect(throws: EditorScriptError.failed(step: 0, "unknown media m9")) {
            try EditorScript(steps: [.clickMedia("m9", .plain)]).run(on: session)
        }
        #expect(throws: EditorScriptError.self) {
            try EditorScript(steps: [.removeSelectedCaptures, .removeSelectedCaptures]).run(on: session)
        }
    }

    /// Navigation that shows another capture by other means (selecting an annotation, undo)
    /// collapses the strip's selection to it.
    @Test func showingAnotherCaptureCollapsesTheSelection() throws {
        let fixture = try Fixture()
        try fixture.store.add(fixture.capture(width: 300, height: 300))
        try fixture.store.add(fixture.capture(width: 300, height: 300))
        let session = try fixture.session()
        session.editor.show(mediaId: "m2")
        AnnotationEditorTests.draw(&session.editor, .rect, [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 120)])
        let onM2 = try #require(session.editor.selection)
        session.editor.clickMedia("m1", .plain)
        session.editor.clickMedia("m3", .toggle)
        #expect(session.editor.selectedMediaIds == ["m1", "m3"])
        session.editor.select(onM2)
        #expect(session.editor.currentMediaId == "m2" && session.editor.selectedMediaIds == ["m2"])
        session.editor.clickMedia("m3", .extend)
        #expect(session.editor.selectedMediaIds == ["m2", "m3"] && session.editor.currentMediaId == "m3")
        session.editor.show(mediaId: "m1")
        #expect(session.editor.selectedMediaIds == ["m1"])
        session.editor.clickMedia("m9", .toggle) // unknown: nothing
        #expect(session.editor.selectedMediaIds == ["m1"])
    }

    @Test func aRemovedIdReusedByTheNextCaptureShowsTheNewFile() throws {
        let fixture = try Fixture()
        try fixture.store.add(fixture.capture(width: 300, height: 300))
        let session = try fixture.session()
        session.editor.show(mediaId: "m2")
        #expect(session.displayImage("m2")?.width == 300) // cached
        try fixture.store.removeMedia("m2", from: fixture.draft.directory)
        // Numbering is monotonic now (docs/07 §7.2), but a draft from before numbering.json
        // could still reuse the last removed capture's id and file name: simulate that.
        try FileManager.default.removeItem(at: fixture.draft.directory.appendingPathComponent(DraftNumbering.filename))
        try fixture.store.add(fixture.capture(width: 120, height: 80, capturedAt: Date(timeIntervalSince1970: 60)))
        let reused = try fixture.onDisk().media.last
        #expect(reused?.id == "m2" && reused?.filename == "capture-2.png")
        #expect(try session.reload() == MediaChanges(added: ["m2"], removed: ["m2"]))
        #expect(session.displayImage("m2")?.width == 120)
    }
}
