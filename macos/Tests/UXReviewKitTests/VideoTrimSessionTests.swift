import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import UXReviewKit

/// End to end through real files: a draft holding a real H.264 movie, trimmed and annotated with
/// time ranges by `EditorSession` / `EditorScript`, saved (AVFoundation export), reopened, and
/// restored. The movie is 2 s at 10 fps: red for the first second, blue for the second.
@Suite(.timeLimit(.minutes(2)))
struct VideoTrimSessionTests {
    final class Fixture {
        let base: URL
        let store: ReviewDraftStore
        let draft: ReviewDraft

        init() async throws {
            base = try TestSupport.makeTempDirectory()
            store = ReviewDraftStore(root: base.appendingPathComponent("Drafts"))
            let movie = base.appendingPathComponent("source.mov")
            let duration = try await Self.writeMovie(to: movie)
            draft = try store.add(DraftCapture(
                fileURL: movie, kind: .video, pixelWidth: 160, pixelHeight: 90, durationMs: duration,
                capturedAt: Date(timeIntervalSince1970: 0), context: CaptureContext()
            )).draft
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        static func writeMovie(to url: URL) async throws -> Int {
            let writer = try VideoFileWriter(url: url, width: 160, height: 90, framesPerSecond: 10)
            let red = try #require(VideoFileWriter.pixelBuffer(from: solid(1, 0, 0), width: 160, height: 90))
            let blue = try #require(VideoFileWriter.pixelBuffer(from: solid(0, 0, 1), width: 160, height: 90))
            for index in 0 ..< 20 {
                let time = CMTime(value: CMTimeValue(index * 60), timescale: 600)
                while !writer.append(index < 10 ? red : blue, at: time) {
                    try await Task.sleep(for: .milliseconds(5))
                    if writer.framesDropped > 2000 { throw VideoWriterError.failed("encoder never became ready") }
                }
            }
            return try await writer.finish(at: CMTime(seconds: 2, preferredTimescale: 600))
        }

        static func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) throws -> CGImage {
            let context = try #require(CGContext(
                data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
            return try #require(context.makeImage())
        }

        var movieURL: URL { draft.directory.appendingPathComponent("capture-1.mov") }
        var originalURL: URL { draft.directory.appendingPathComponent("originals/capture-1.mov") }

        func session() throws -> EditorSession { try EditorSession(store: store, directory: draft.directory) }

        func onDisk() throws -> ReviewBundle { try store.load(draft.directory).bundle }
    }

    /// "red" or "blue": the dominant channel of the image's average color.
    static func color(_ frame: CGImage?) throws -> String {
        let image = try #require(frame)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[0] > pixel[2] ? "red" : "blue"
    }

    static func duration(_ url: URL) async throws -> Int { try await VideoFileWriter.inspect(url).durationMs }

    @Test func showsTheFrameAtThePlayhead() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session()
        #expect(try Self.color(session.displayImage("m1")) == "red")
        session.editor.setCurrentTime(1500)
        #expect(try Self.color(session.displayImage("m1")) == "blue")
        #expect(try Self.color(session.displayImage("m1", atMs: 200)) == "red")
        session.editor.setCurrentTime(session.editor.currentDurationMs ?? 0)
        #expect(try Self.color(session.displayImage("m1")) == "blue", "the clip's end shows its last frame")
    }

    @Test func trimWritesTheClipKeepsTheOriginalAndReopensRestorable() async throws {
        let fixture = try await Fixture()
        let originalBytes = try Data(contentsOf: fixture.movieURL)
        let originalDuration = try #require(fixture.onDisk().media[0].durationMs)
        let session = try fixture.session()
        AnnotationEditorTests.draw(&session.editor, .rect, [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 50)])
        let done1 = session.editor.setTimeRange(TimeRange(startMs: 1200, endMs: 1800), for: "a1")
        #expect(done1)
        let done2 = session.editor.trim(to: TimeRange(startMs: 1000, endMs: originalDuration))
        #expect(done2)
        let kept = originalDuration - 1000
        try session.save()

        // The file is the trimmed clip (blue only), review.json agrees, and the original is kept.
        let disk = try fixture.onDisk()
        #expect(disk.validate().isEmpty)
        #expect(disk.media[0].durationMs == kept)
        #expect(disk.annotations[0].timeRange == TimeRange(startMs: 200, endMs: 800))
        let length1 = try await Self.duration(fixture.movieURL)
        #expect(abs(length1 - kept) <= 110, "within a frame")
        #expect(try Data(contentsOf: fixture.originalURL) == originalBytes)
        #expect(
            OriginalsIndex.load(from: fixture.originalURL.deletingLastPathComponent()).trims["capture-1.mov"]
                == TrimRecord(startMs: 1000, endMs: originalDuration, originalDurationMs: originalDuration)
        )
        #expect(try Self.color(session.displayImage("m1", atMs: 0)) == "blue")

        // A new session starts trimmed (not dirty), shows the clip, and restores the original.
        let reopened = try fixture.session()
        #expect(!reopened.editor.isDirty && reopened.editor.canRestoreOriginal)
        #expect(reopened.editor.document.trims["m1"] == TimeRange(startMs: 1000, endMs: originalDuration))
        #expect(try Self.color(reopened.displayImage("m1", atMs: 0)) == "blue")
        let done3 = reopened.editor.restoreOriginal()
        #expect(done3)
        #expect(reopened.editor.annotation("a1")?.timeRange == TimeRange(startMs: 1200, endMs: 1800))
        try reopened.save()
        #expect(try Data(contentsOf: fixture.movieURL) == originalBytes, "restored byte for byte")
        #expect(try fixture.onDisk().media[0].durationMs == originalDuration)
        #expect(try fixture.onDisk().validate().isEmpty)
        #expect(try Self.color(reopened.displayImage("m1", atMs: 0)) == "red")
    }

    @Test func trimStaysUndoableAfterSavingAndComposesFromTheOriginal() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session()
        let full = try #require(session.editor.currentDurationMs)
        let done4 = session.editor.trim(to: TimeRange(startMs: 0, endMs: 1000))
        #expect(done4)
        try session.save()
        #expect(try Self.color(session.displayImage("m1", atMs: 900)) == "red")
        session.editor.undo()
        try session.save()
        #expect(try fixture.onDisk().media[0].durationMs == full)
        let length2 = try await Self.duration(fixture.movieURL)
        #expect(abs(length2 - full) <= 110)
        session.editor.redo()
        session.editor.setCurrentTime(500)
        let trimmed = session.editor.trimStartToPlayhead() // 500…1000 of the original
        #expect(trimmed)
        try session.save()
        #expect(session.editor.document.trims["m1"] == TimeRange(startMs: 500, endMs: 1000))
        let length3 = try await Self.duration(fixture.movieURL)
        #expect(abs(length3 - 500) <= 110)
        #expect(try fixture.onDisk().validate().isEmpty)
    }

    @Test func anUntrustedOriginalIsNeverOverwritten() async throws {
        let fixture = try await Fixture()
        // An original with no trim record (for example, copied by hand).
        try FileManager.default.createDirectory(at: fixture.originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a movie".utf8).write(to: fixture.originalURL)
        let session = try fixture.session()
        #expect(!session.editor.canRestoreOriginal)
        let done5 = session.editor.trim(to: TimeRange(startMs: 1000, endMs: 1900))
        #expect(done5)
        try session.save()
        #expect(try Self.color(session.displayImage("m1", atMs: 0)) == "blue")
        session.editor.undo() // back to the file as this session found it
        try session.save()
        #expect(try Self.color(session.displayImage("m1", atMs: 0)) == "red")
        #expect(try Data(contentsOf: fixture.originalURL) == Data("not a movie".utf8))
        #expect(OriginalsIndex.load(from: fixture.originalURL.deletingLastPathComponent()).trims.isEmpty)
    }

    @Test func scriptDrivesTimeRangesAndTrims() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session()
        let script = try EditorScript.parse(Data("""
        {"steps": [
          {"op": "tool", "tool": "rect"}, {"op": "drag", "points": [[10, 10], [80, 50]]},
          {"op": "range", "start": 1500, "end": 1700},
          {"op": "time", "ms": 1600},
          {"op": "tool", "tool": "strike"}, {"op": "drag", "points": [[90, 10], [150, 60]]},
          {"op": "range", "start": 100, "end": 300},
          {"op": "trim", "start": 1000, "end": 1900},
          {"op": "select", "id": "a1"}, {"op": "range"}
        ]}
        """.utf8))
        let messages = try script.run(on: session)
        #expect(messages.contains("Trimmed to 0.9 s. Removed 1 annotation outside the trim."))
        let disk = try fixture.onDisk()
        #expect(disk.annotations.map(\.id) == ["a1"])
        #expect(disk.annotations[0].timeRange == nil)
        #expect(disk.media[0].durationMs == 900)
        #expect(disk.validate().isEmpty)

        let bad = try EditorScript.parse(Data(#"{"steps": [{"op": "select"}, {"op": "range", "start": 0, "end": 10}]}"#.utf8))
        #expect(throws: EditorScriptError.failed(step: 1, "nothing selected")) { try bad.run(on: session) }
    }

    @Test func renderAnnotatedDrawsOnlyAnnotationsShowingAtThePlayhead() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session()
        AnnotationEditorTests.draw(&session.editor, .rect, [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 50)])
        session.editor.setTimeRange(TimeRange(startMs: 1000, endMs: 1500), for: "a1")
        session.editor.setCurrentTime(0)
        #expect(session.renderItems("m1").isEmpty)
        session.editor.setCurrentTime(1200)
        #expect(session.renderItems("m1").map(\.annotation.id) == ["a1"])
        #expect(session.renderAnnotated("m1") != nil)
    }
}

struct VideoScriptParsingTests {
    @Test func parsesTimeRangeTrimAndRestoreOps() throws {
        let script = try EditorScript.parse(Data("""
        {"steps": [
          {"op": "time", "ms": 250}, {"op": "range", "start": 1, "end": 2}, {"op": "range"},
          {"op": "trim", "start": 10, "end": 20}, {"op": "reset-trim"}, {"op": "restore-original"}, {"op": "reset-crop"}
        ]}
        """.utf8))
        #expect(script.steps == [
            .time(250), .range(TimeRange(startMs: 1, endMs: 2)), .range(nil),
            .trim(TimeRange(startMs: 10, endMs: 20)), .resetTrim, .restoreOriginal, .resetCrop,
        ])
        for bad in [#"{"op": "range", "start": 1}"#, #"{"op": "trim"}"#, #"{"op": "trim", "end": 3}"#, #"{"op": "time"}"#] {
            #expect(throws: DecodingError.self) { try EditorScript.parse(Data(#"{"steps": [\#(bad)]}"#.utf8)) }
        }
    }

    @Test func timeStepFailsOnImagesAndRangeFailsOnImageAnnotations() throws {
        let base = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ReviewDraftStore(root: base.appendingPathComponent("Drafts"))
        let draft = try store.add(EditorSessionTests.Fixture.capture(in: base, width: 200, height: 100)).draft
        let session = try EditorSession(store: store, directory: draft.directory)
        let time = try EditorScript.parse(Data(#"{"steps": [{"op": "time", "ms": 5}]}"#.utf8))
        #expect(throws: EditorScriptError.failed(step: 0, "the current media is not a video")) { try time.run(on: session) }
        let range = try EditorScript.parse(Data("""
        {"steps": [{"op": "tool", "tool": "insertion"}, {"op": "drag", "points": [[5, 5]]}, {"op": "range", "start": 0, "end": 1}]}
        """.utf8))
        #expect(throws: EditorScriptError.failed(step: 2, "time ranges apply to annotations on videos")) { try range.run(on: session) }
    }
}
