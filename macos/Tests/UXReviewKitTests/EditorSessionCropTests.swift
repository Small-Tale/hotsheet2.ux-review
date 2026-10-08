import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// docs/06 §6.6 through real files: crops are recorded in edits.json and never applied to the
/// capture file until submitting (HS2-71SSJG), and drafts cropped the old way migrate on open.
extension EditorSessionTests {
    /// HS2-71SSJG: a crop is recorded in edits.json, never applied to the file, and annotations
    /// are saved in the file's own coordinates; undo after saving still works.
    @Test func cropIsRecordedNotAppliedAndStaysUndoableAfterSaving() throws {
        let fixture = try Fixture()
        let session = try fixture.session()
        let file = fixture.draft.directory.appendingPathComponent("capture-1.png")
        let original = try Data(contentsOf: file)
        AnnotationEditorTests.draw(&session.editor, .rect, [CGPoint(x: 120, y: 60), CGPoint(x: 160, y: 100)])
        let cropped = session.editor.crop(to: CGRect(x: 100, y: 50, width: 200, height: 100))
        #expect(cropped)
        #expect(session.displayImage("m1")?.width == 200)
        #expect(session.editor.bundle.annotations[0].shape == .rect(NormRect(x: 1000, y: 1000, width: 2000, height: 4000)))
        try session.save()

        #expect(try Data(contentsOf: file) == original, "the capture file is never rewritten")
        #expect(!FileManager.default.fileExists(atPath: fixture.draft.directory.appendingPathComponent("originals").path))
        #expect(
            DraftEdits.load(from: fixture.draft.directory)
                .crops == ["capture-1.png": PixelRect(x: 100, y: 50, width: 200, height: 100)]
        )
        var disk = try fixture.onDisk()
        #expect(disk.media[0].pixelWidth == 400 && disk.media[0].pixelHeight == 200)
        #expect(disk.annotations[0].shape == .rect(NormRect(x: 3000, y: 3000, width: 1000, height: 2000)))
        #expect(disk.validate().isEmpty)

        // Undo after the save: the next save forgets the crop (and removes edits.json).
        session.editor.undo()
        try session.save()
        #expect(!FileManager.default.fileExists(atPath: DraftEdits.url(in: fixture.draft.directory).path))
        disk = try fixture.onDisk()
        #expect(disk.annotations[0].shape == .rect(NormRect(x: 3000, y: 3000, width: 1000, height: 2000)))
        // Redo and save; a new session starts cropped, not dirty, with the annotation in crop space.
        session.editor.redo()
        try session.save()
        let next = try fixture.session()
        #expect(next.editor.document.crops["m1"] == PixelRect(x: 100, y: 50, width: 200, height: 100))
        #expect(next.editor.bundle.annotations[0].shape == .rect(NormRect(x: 1000, y: 1000, width: 2000, height: 4000)))
        #expect(!next.editor.isDirty && next.displayImage("m1")?.width == 200)
        #expect(try Data(contentsOf: file) == original)
    }

    /// HS2-71SSJG: annotations outside a crop survive saving and reopening, and come back
    /// exactly when a later session restores the original; crops in later sessions compose;
    /// reopening and saving many times never drifts.
    @Test func aLaterSessionRestoresAndRecropsWithoutLoss() throws {
        let fixture = try Fixture()
        let file = fixture.draft.directory.appendingPathComponent("capture-1.png")
        let originalPixels = try Self.pixels(file)
        let first = try fixture.session()
        AnnotationEditorTests.draw(&first.editor, .rect, [CGPoint(x: 120, y: 60), CGPoint(x: 160, y: 100)])
        AnnotationEditorTests.draw(&first.editor, .insertion, [CGPoint(x: 350, y: 180)]) // outside the crop below
        let drawn = first.editor.bundle.annotations.map(\.shape)
        _ = first.editor.crop(to: CGRect(x: 100, y: 50, width: 200, height: 100))
        #expect(first.editor.annotation("a2").map(first.editor.isOutsideEdit) == true)
        try first.save()
        #expect(try fixture.onDisk().annotations.map(\.shape) == drawn, "saved in the file's coordinates, outsider included")

        // Many sessions that change nothing: the stored shapes never drift by rounding.
        for _ in 0 ..< 5 {
            let idle = try fixture.session()
            #expect(!idle.editor.isDirty)
            AnnotationEditorTests.draw(&idle.editor, .insertion, [CGPoint(x: 50, y: 50)])
            idle.editor.undo()
            idle.editor.redo()
            idle.editor.undo()
            try idle.save()
        }
        #expect(try fixture.onDisk().annotations.map(\.shape) == drawn)

        let second = try fixture.session()
        let restored = second.editor.resetCrop()
        #expect(restored)
        #expect(second.editor.bundle.annotations.map(\.shape) == drawn, "both back where they were drawn")
        try second.save()
        #expect(!FileManager.default.fileExists(atPath: DraftEdits.url(in: fixture.draft.directory).path))
        #expect(try Self.pixels(file) == originalPixels)

        // Undo the restore, then crop again: the new crop composes relative to the original.
        second.editor.undo()
        _ = second.editor.crop(to: CGRect(x: 10, y: 10, width: 50, height: 40))
        try second.save()
        #expect(DraftEdits.load(from: fixture.draft.directory).crops["capture-1.png"] == PixelRect(x: 110, y: 60, width: 50, height: 40))
        #expect(try fixture.onDisk().annotations.map(\.shape) == drawn)

        // Session 3 restores in one step from two sessions of crops.
        let third = try fixture.session()
        let restoredAgain = third.editor.resetCrop()
        #expect(restoredAgain)
        #expect(third.editor.bundle.annotations.map(\.shape) == drawn)
        try third.save()
        #expect(try Self.pixels(file) == originalPixels)
        let fourth = try fixture.session()
        #expect(fourth.editor.document.crops["m1"] == nil)
    }

    /// Drafts cropped before HS2-71SSJG (a cropped file, its original under originals/, and
    /// crops.json) convert on open: the original goes back in place, annotations map back
    /// exactly, and the crop moves to edits.json. Untrusted records leave the file as it is.
    @Test func legacyCroppedDraftsMigrateOnOpen() throws {
        let fixture = try Fixture()
        let directory = fixture.draft.directory
        let file = directory.appendingPathComponent("capture-1.png")
        let originals = directory.appendingPathComponent("originals")
        let originalPixels = try Self.pixels(file)
        let crop = PixelRect(x: 100, y: 50, width: 200, height: 100)
        func makeLegacy(index: Data?) throws {
            try? FileManager.default.removeItem(at: originals)
            try? FileManager.default.removeItem(at: DraftEdits.url(in: directory))
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            let card = try #require(ImageFiles.testCard(width: 400, height: 200))
            try ImageFiles.writePNG(card, to: originals.appendingPathComponent("capture-1.png"))
            try ImageFiles.writePNG(#require(ImageCrop.apply(crop, to: card)), to: file)
            if let index { try index.write(to: OriginalsIndex.url(in: originals)) }
            try fixture.store.update(directory) { bundle in
                bundle.media[0].pixelWidth = 200
                bundle.media[0].pixelHeight = 100
                bundle.annotations = [Annotation(
                    id: "a1", mediaId: "m1", shape: .rect(NormRect(x: 1000, y: 1000, width: 2000, height: 4000)), intents: [.comment],
                    note: ""
                )]
            }
        }
        try makeLegacy(index: Data(#"{"version": 1, "crops": {"capture-1.png": {"x": 100, "y": 50, "width": 200, "height": 100}}}"#.utf8))
        let session = try fixture.session()
        #expect(try Self.pixels(file) == originalPixels, "the original is back in place")
        #expect(!FileManager.default.fileExists(atPath: originals.path))
        #expect(DraftEdits.load(from: directory).crops == ["capture-1.png": crop])
        let disk = try fixture.onDisk()
        #expect(disk.media[0].pixelWidth == 400)
        #expect(disk.annotations[0].shape == .rect(NormRect(x: 3000, y: 3000, width: 1000, height: 2000)))
        #expect(session.editor.document.crops["m1"] == crop)
        #expect(session.editor.bundle.annotations[0].shape == .rect(NormRect(x: 1000, y: 1000, width: 2000, height: 4000)))
        #expect(!session.editor.isDirty && session.displayImage("m1")?.width == 200)

        let untrusted: [(String, Data?)] = [
            ("no index", nil),
            ("unreadable index", Data("{not json".utf8)),
            ("wrong version", Data(#"{"version": 9, "crops": {"capture-1.png": {"x": 100, "y": 50, "width": 200, "height": 100}}}"#.utf8)),
            ("size mismatch", Data(#"{"version": 1, "crops": {"capture-1.png": {"x": 0, "y": 0, "width": 300, "height": 100}}}"#.utf8)),
        ]
        for (name, index) in untrusted {
            try makeLegacy(index: index)
            let opened = try fixture.session()
            #expect(try fixture.fileSize("capture-1.png") == (200, 100), "\(name): the file stays as found")
            #expect(opened.editor.document.crops.isEmpty, "\(name)")
            #expect(DraftEdits.load(from: directory).isEmpty, "\(name)")
            #expect(FileManager.default.fileExists(atPath: originals.appendingPathComponent("capture-1.png").path), "\(name): kept")
            #expect(try fixture.onDisk().annotations[0].shape == .rect(NormRect(x: 1000, y: 1000, width: 2000, height: 4000)), "\(name)")
        }
    }
}
