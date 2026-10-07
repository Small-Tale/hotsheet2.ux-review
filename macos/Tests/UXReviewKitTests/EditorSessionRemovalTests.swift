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

    @Test func aRemovedIdReusedByTheNextCaptureShowsTheNewFile() throws {
        let fixture = try Fixture()
        try fixture.store.add(fixture.capture(width: 300, height: 300))
        let session = try fixture.session()
        session.editor.show(mediaId: "m2")
        #expect(session.displayImage("m2")?.width == 300) // cached
        try fixture.store.removeMedia("m2", from: fixture.draft.directory)
        // Removing the last capture frees both its id and its file name for the next one.
        try fixture.store.add(fixture.capture(width: 120, height: 80, capturedAt: Date(timeIntervalSince1970: 60)))
        let reused = try fixture.onDisk().media.last
        #expect(reused?.id == "m2" && reused?.filename == "capture-2.png")
        #expect(try session.reload() == MediaChanges(added: ["m2"], removed: ["m2"]))
        #expect(session.displayImage("m2")?.width == 120)
    }
}
