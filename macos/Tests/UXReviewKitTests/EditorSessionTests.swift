import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// End to end through real files: a draft created by `ReviewDraftStore`, edited by
/// `EditorSession` (and `EditorScript`), saved, cropped on disk, and read back.
struct EditorSessionTests {
    final class Fixture {
        let base: URL
        let store: ReviewDraftStore
        let draft: ReviewDraft

        /// A draft with one 400 × 200 test-card PNG.
        init(width: Int = 400, height: Int = 200) throws {
            base = try TestSupport.makeTempDirectory()
            store = ReviewDraftStore(root: base.appendingPathComponent("Drafts"))
            draft = try store.add(Self.capture(in: base, width: width, height: height)).draft
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        func capture(width: Int = 400, height: Int = 200) throws -> DraftCapture {
            try Self.capture(in: base, width: width, height: height)
        }

        static func capture(in base: URL, width: Int, height: Int) throws -> DraftCapture {
            let url = base.appendingPathComponent("shot-\(UUID().uuidString).png")
            try ImageFiles.writePNG(#require(ImageFiles.testCard(width: width, height: height)), to: url)
            return DraftCapture(
                fileURL: url, kind: .image, pixelWidth: width, pixelHeight: height,
                capturedAt: Date(timeIntervalSince1970: 0), context: CaptureContext(appName: "Safari")
            )
        }

        func session() throws -> EditorSession { try EditorSession(store: store, directory: draft.directory) }

        func onDisk() throws -> ReviewBundle { try store.load(draft.directory).bundle }

        func fileSize(_ name: String) throws -> (Int, Int) {
            let size = try ImageFiles.pixelSize(of: draft.directory.appendingPathComponent(name))
            return (size.width, size.height)
        }
    }

    @Test func savesAnnotationsThatValidateAndReloadIdentically() throws {
        let fixture = try Fixture()
        let session = try fixture.session()
        AnnotationEditorTests.draw(&session.editor, .rect, [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60)])
        session.editor.setNote("**Clipped** label", for: "a1")
        session.editor.toggleIntent(.bug, for: "a1")
        #expect(session.editor.isDirty)
        try session.save()
        #expect(!session.editor.isDirty)

        let disk = try fixture.onDisk()
        #expect(disk.validate().isEmpty)
        #expect(disk.annotations == session.editor.bundle.annotations)
        #expect(disk.annotations[0].intents == [.comment, .bug])
        let reopened = try fixture.session()
        #expect(reopened.editor.bundle == disk)
        #expect(!reopened.editor.canUndo)
    }

    @Test func savingKeepsCapturesAddedWhileEditing() throws {
        let fixture = try Fixture()
        let session = try fixture.session()
        AnnotationEditorTests.draw(&session.editor, .insertion, [CGPoint(x: 5, y: 5)])
        try fixture.store.add(fixture.capture(width: 100, height: 100)) // captured meanwhile
        let added = try session.save()
        #expect(added == ["m2"])
        let disk = try fixture.onDisk()
        #expect(disk.media.map(\.filename) == ["capture-1.png", "capture-2.png"])
        #expect(disk.annotations.count == 1)
        #expect(session.editor.bundle.media.count == 2)
        // A reload with nothing new is a no-op.
        #expect(try session.reload().isEmpty)
    }

    @Test func cropRewritesTheImageKeepsTheOriginalAndStaysUndoableAfterSaving() throws {
        let fixture = try Fixture()
        let session = try fixture.session()
        let original = try Data(contentsOf: fixture.draft.directory.appendingPathComponent("capture-1.png"))
        AnnotationEditorTests.draw(&session.editor, .rect, [CGPoint(x: 120, y: 60), CGPoint(x: 160, y: 100)])
        let cropped = session.editor.crop(to: CGRect(x: 100, y: 50, width: 200, height: 100))
        #expect(cropped)
        #expect(session.displayImage("m1")?.width == 200)
        try session.save()

        #expect(try fixture.fileSize("capture-1.png") == (200, 100))
        let kept = fixture.draft.directory.appendingPathComponent("originals/capture-1.png")
        #expect(try Data(contentsOf: kept) == original)
        var disk = try fixture.onDisk()
        #expect(disk.media[0].pixelWidth == 200 && disk.media[0].pixelHeight == 100)
        #expect(disk.annotations[0].shape == .rect(NormRect(x: 1000, y: 1000, width: 2000, height: 4000)))
        #expect(disk.validate().isEmpty)

        // Undo after the save: the next save restores the full image from the session's copy.
        session.editor.undo()
        try session.save()
        #expect(try fixture.fileSize("capture-1.png") == (400, 200))
        disk = try fixture.onDisk()
        #expect(disk.media[0].pixelWidth == 400)
        // Redo, save, then crop again in a new session: the original from capture time is kept.
        session.editor.redo()
        try session.save()
        let next = try fixture.session()
        _ = next.editor.crop(to: CGRect(x: 0, y: 0, width: 100, height: 50))
        try next.save()
        #expect(try fixture.fileSize("capture-1.png") == (100, 50))
        #expect(try Data(contentsOf: kept) == original)
    }

    /// RGBA bytes of an image file, for pixel-exact comparisons.
    static func pixels(_ url: URL) throws -> [UInt8] {
        let image = try ImageFiles.loadImage(at: url)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// Crop and save in one session; a later session restores the original, maps the
    /// annotations back, and keeps every step undoable; crops in later sessions compose.
    @Test func aLaterSessionRestoresTheOriginal() throws {
        let fixture = try Fixture()
        let file = fixture.draft.directory.appendingPathComponent("capture-1.png")
        let originalPixels = try Self.pixels(file)
        let first = try fixture.session()
        #expect(first.resetRestoresOriginal("m1")) // nothing kept yet: the file is the original
        AnnotationEditorTests.draw(&first.editor, .rect, [CGPoint(x: 120, y: 60), CGPoint(x: 160, y: 100)])
        let drawn = first.editor.bundle.annotations[0].shape
        _ = first.editor.crop(to: CGRect(x: 100, y: 50, width: 200, height: 100))
        try first.save()
        let index = OriginalsIndex.load(from: fixture.draft.directory.appendingPathComponent("originals"))
        #expect(index.crops == ["capture-1.png": PixelRect(x: 100, y: 50, width: 200, height: 100)])

        // Session 2 starts from the original with the crop applied, and is not dirty.
        let second = try fixture.session()
        #expect(second.resetRestoresOriginal("m1"))
        #expect(second.editor.document.crops["m1"] == PixelRect(x: 100, y: 50, width: 200, height: 100))
        #expect(second.editor.originalSizes["m1"] == PixelRect(x: 0, y: 0, width: 400, height: 200))
        #expect(!second.editor.isDirty)
        #expect(second.displayImage("m1")?.width == 200)
        try second.save() // nothing changed: the file is not rewritten
        #expect(try fixture.fileSize("capture-1.png") == (200, 100))

        let restored = second.editor.resetCrop()
        #expect(restored)
        #expect(second.editor.bundle.annotations[0].shape == drawn) // back where it was drawn
        try second.save()
        #expect(try fixture.fileSize("capture-1.png") == (400, 200))
        #expect(try Self.pixels(file) == originalPixels)
        #expect(try fixture.onDisk().media[0].pixelWidth == 400)

        // Undo the restore, then crop again: the new crop composes relative to the original.
        second.editor.undo()
        _ = second.editor.crop(to: CGRect(x: 10, y: 10, width: 50, height: 40))
        try second.save()
        #expect(try fixture.fileSize("capture-1.png") == (50, 40))
        let composed = OriginalsIndex.load(from: fixture.draft.directory.appendingPathComponent("originals"))
        #expect(composed.crops["capture-1.png"] == PixelRect(x: 110, y: 60, width: 50, height: 40))

        // Session 3 restores in one step from two sessions of crops; the index then records the full image.
        let third = try fixture.session()
        let restoredAgain = third.editor.resetCrop()
        #expect(restoredAgain)
        try third.save()
        #expect(try Self.pixels(file) == originalPixels)
        let full = OriginalsIndex.load(from: fixture.draft.directory.appendingPathComponent("originals"))
        #expect(full.crops["capture-1.png"] == PixelRect(x: 0, y: 0, width: 400, height: 200))
        let fourth = try fixture.session()
        #expect(fourth.editor.document.crops["m1"] == nil) // nothing to restore any more
        #expect(fourth.resetRestoresOriginal("m1"))
    }

    /// Originals kept before crops were recorded, or an index that doesn't match the files, are
    /// never trusted: editing still works, relative to the file as found.
    @Test func untrustedOriginalsFallBackToTheCurrentFile() throws {
        let fixture = try Fixture()
        let originals = fixture.draft.directory.appendingPathComponent("originals")
        let first = try fixture.session()
        _ = first.editor.crop(to: CGRect(x: 100, y: 50, width: 200, height: 100))
        try first.save()

        let cases: [(String, Data?)] = [
            ("no index (a legacy draft)", nil),
            ("unreadable index", Data("{not json".utf8)),
            ("wrong version", Data(#"{"version": 9, "crops": {"capture-1.png": {"x": 100, "y": 50, "width": 200, "height": 100}}}"#.utf8)),
            ("size mismatch", Data(#"{"version": 1, "crops": {"capture-1.png": {"x": 0, "y": 0, "width": 300, "height": 100}}}"#.utf8)),
            (
                "outside the original",
                Data(#"{"version": 1, "crops": {"capture-1.png": {"x": 300, "y": 150, "width": 200, "height": 100}}}"#.utf8)
            ),
        ]
        for (name, data) in cases {
            try? FileManager.default.removeItem(at: OriginalsIndex.url(in: originals))
            if let data { try data.write(to: OriginalsIndex.url(in: originals)) }
            let session = try fixture.session()
            #expect(session.editor.document.crops.isEmpty, "\(name)")
            #expect(!session.resetRestoresOriginal("m1"), "\(name)")
            #expect(session.displayImage("m1")?.width == 200, "\(name)")
        }
        // Cropping an untrusted image works and drops its (unknown) record.
        let session = try fixture.session()
        _ = session.editor.crop(to: CGRect(x: 0, y: 0, width: 100, height: 50))
        try session.save()
        #expect(try fixture.fileSize("capture-1.png") == (100, 50))
        #expect(OriginalsIndex.load(from: originals).crops["capture-1.png"] == nil)
        #expect(try ImageFiles.pixelSize(of: originals.appendingPathComponent("capture-1.png")) == (400, 200)) // still untouched
    }

    @Test func priorCropRules() {
        let index = OriginalsIndex(crops: ["a.png": PixelRect(x: 10, y: 10, width: 50, height: 40)])
        let original = PixelRect(x: 0, y: 0, width: 100, height: 80)
        #expect(
            index.prior(filename: "a.png", originalSize: original, currentWidth: 50, currentHeight: 40)
                == PriorCrop(originalSize: original, crop: PixelRect(x: 10, y: 10, width: 50, height: 40))
        )
        #expect(index.prior(filename: "a.png", originalSize: nil, currentWidth: 50, currentHeight: 40) == nil)
        #expect(index.prior(filename: "a.png", originalSize: original, currentWidth: 51, currentHeight: 40) == nil)
        // No record: same size as the original means identical; any other size is unknown.
        #expect(index.prior(filename: "b.png", originalSize: original, currentWidth: 100, currentHeight: 80)?.crop == original)
        #expect(index.prior(filename: "b.png", originalSize: original, currentWidth: 60, currentHeight: 80) == nil)
    }

    @Test func aMissingImageFailsTheSaveWithoutWritingTheBundle() throws {
        let fixture = try Fixture()
        let session = try fixture.session()
        _ = session.editor.crop(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        try FileManager.default.removeItem(at: fixture.draft.directory.appendingPathComponent("capture-1.png"))
        #expect(throws: ImageFileError.self) { try session.save() }
        #expect(try fixture.onDisk().media[0].pixelWidth == 400)
        #expect(session.displayImage("m1") == nil)
    }

    @Test func renderingDrawsTheAnnotationsOntoTheImage() throws {
        let fixture = try Fixture()
        let session = try fixture.session()
        AnnotationEditorTests.draw(&session.editor, .rect, [CGPoint(x: 100, y: 50), CGPoint(x: 300, y: 150)])
        session.editor.toggleIntent(.bug, for: "a1")
        session.editor.toggleIntent(.comment, for: "a1") // bug only: red stroke
        let plain = try #require(session.displayImage("m1"))
        let drawn = try #require(session.renderAnnotated("m1"))
        #expect(drawn.width == plain.width && drawn.height == plain.height)
        // The left edge of the box (x = 100, mid-height) is stroked in the bug color.
        let pixel = try #require(Self.rgb(drawn, x: 100, y: 100))
        #expect(pixel.red > 200 && pixel.green < 120 && pixel.blue < 120)
        // Far from any annotation the image is untouched.
        #expect(Self.rgb(drawn, x: 380, y: 190).map { "\($0)" } == Self.rgb(plain, x: 380, y: 190).map { "\($0)" })
    }

    @Test func scriptsDriveTheSameEditor() throws {
        let fixture = try Fixture()
        let session = try fixture.session()
        let script = try EditorScript.parse(Data("""
        {"steps": [
          {"op": "tool", "tool": "rect"},
          {"op": "drag", "points": [[20, 20], [120, 80]]},
          {"op": "note", "text": "Too tight"},
          {"op": "intent", "intent": "change"},
          {"op": "tool", "tool": "arrow"},
          {"op": "drag", "points": [[200, 100], [300, 150]]},
          {"op": "tool", "tool": "freehand"},
          {"op": "drag", "points": [[300, 20], [350, 20], [350, 70], [300, 70]]},
          {"op": "closed", "closed": false},
          {"op": "delete"},
          {"op": "undo"},
          {"op": "select", "id": "#1"},
          {"op": "duplicate"},
          {"op": "nudge", "dx": 4, "dy": 0},
          {"op": "tool", "tool": "strike"},
          {"op": "cancel-drag", "points": [[0, 0], [50, 50]]},
          {"op": "crop", "rect": [10, 10, 380, 180]},
          {"op": "select"},
          {"op": "save"}
        ]}
        """.utf8))
        let messages = try script.run(on: session)
        #expect(messages == ["Cropped to 380 × 180 px."])
        let disk = try fixture.onDisk()
        #expect(disk.annotations.map(\.shape.kind) == ["rect", "arrow", "freehand", "rect"])
        #expect(disk.annotations[0].note == "Too tight" && disk.annotations[0].intents == [.comment, .change])
        #expect(disk.annotations[3].note == "Too tight")
        #expect(disk.validate().isEmpty)
        #expect(try fixture.fileSize("capture-1.png") == (380, 180))
    }

    @Test func scriptErrorsNameTheStep() throws {
        let fixture = try Fixture()
        for (json, expected) in [
            (#"{"steps": [{"op": "note", "text": "x"}]}"#, "Step 1: nothing selected"),
            (#"{"steps": [{"op": "undo"}, {"op": "media", "media": "m9"}]}"#, "Step 2: unknown media m9"),
            (##"{"steps": [{"op": "select", "id": "#4"}]}"##, "Step 1: unknown annotation #4"),
            (#"{"steps": [{"op": "delete"}]}"#, "Step 1: nothing selected"),
        ] {
            let script = try EditorScript.parse(Data(json.utf8))
            #expect(throws: EditorScriptError.self) { try script.run(on: fixture.session()) }
            do {
                try script.run(on: fixture.session())
            } catch {
                #expect(expected == "\(error)")
            }
        }
        for bad in [
            #"{"steps": [{"op": "fly"}]}"#,
            #"{"steps": [{"op": "tool", "tool": "lasso"}]}"#,
            #"{"steps": [{"op": "drag", "points": []}]}"#,
            #"{"steps": [{"op": "drag", "points": [[1]]}]}"#,
            #"{"steps": [{"op": "crop", "rect": [1, 2, 3]}]}"#,
            #"{"steps": [{"op": "intent", "intent": "praise"}]}"#,
        ] {
            #expect(throws: DecodingError.self) { try EditorScript.parse(Data(bad.utf8)) }
        }
    }

    @Test func annotateCommandParsing() throws {
        #expect(try AnnotateCommand.parse(["--capture", "screenshot"]) == nil)
        let command = try #require(try AnnotateCommand.parse([
            "--annotate", "s.json", "--drafts-dir", "/d", "--draft", "20261007-1", "--render-dir", "/r",
        ]))
        #expect(command.script.lastPathComponent == "s.json")
        #expect(command.draftsDirectory?.path == "/d" && command.draft == "20261007-1" && command.renderDirectory?.path == "/r")
        #expect(throws: CommandLineError.self) { try AnnotateCommand.parse(["--annotate"]) }
        #expect(throws: CommandLineError.self) { try AnnotateCommand.parse(["--annotate", "s.json", "--draft", "../x"]) }
        #expect(throws: CommandLineError.self) { try AnnotateCommand.parse(["--annotate", "s.json", "--draft", ".."]) }
    }

    static func rgb(_ image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int)? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // Draw so that pixel (x, y) from the top lands on the single output pixel.
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}
