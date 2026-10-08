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

        func capture(width: Int = 400, height: Int = 200, capturedAt: Date = Date(timeIntervalSince1970: 0)) throws -> DraftCapture {
            try Self.capture(in: base, width: width, height: height, capturedAt: capturedAt)
        }

        static func capture(
            in base: URL, width: Int, height: Int, capturedAt: Date = Date(timeIntervalSince1970: 0)
        ) throws -> DraftCapture {
            let url = base.appendingPathComponent("shot-\(UUID().uuidString).png")
            try ImageFiles.writePNG(#require(ImageFiles.testCard(width: width, height: height)), to: url)
            return DraftCapture(
                fileURL: url, kind: .image, pixelWidth: width, pixelHeight: height,
                capturedAt: capturedAt, context: CaptureContext(appName: "Safari")
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
        let changes = try session.save()
        #expect(changes == MediaChanges(added: ["m2"]))
        let disk = try fixture.onDisk()
        #expect(disk.media.map(\.filename) == ["capture-1.png", "capture-2.png"])
        #expect(disk.annotations.count == 1)
        #expect(session.editor.bundle.media.count == 2)
        // A reload with nothing new is a no-op.
        #expect(try session.reload().isEmpty)
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

    /// Saving never touches image files, so a missing one only fails when submitting needs it.
    @Test func aMissingImageFailsTheSubmissionStagingNotTheSave() throws {
        let fixture = try Fixture()
        let session = try fixture.session()
        _ = session.editor.crop(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        try FileManager.default.removeItem(at: fixture.draft.directory.appendingPathComponent("capture-1.png"))
        try session.save()
        #expect(try fixture.onDisk().media[0].pixelWidth == 400)
        #expect(session.displayImage("m1") == nil)
        #expect(throws: (any Error).self) { try SubmissionStaging.prepare(fixture.store.load(fixture.draft.directory)) }
        let staging = fixture.draft.directory.appendingPathComponent(SubmissionStaging.folderName)
        #expect(!FileManager.default.fileExists(atPath: staging.path), "a failed staging cleans up")
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
        #expect(try fixture.fileSize("capture-1.png") == (400, 200))
        #expect(DraftEdits.load(from: fixture.draft.directory).crops["capture-1.png"] == PixelRect(x: 10, y: 10, width: 380, height: 180))
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
