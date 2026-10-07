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
