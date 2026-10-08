import CoreMedia
import Foundation
import Testing
@testable import UXReviewKit

extension EncodingTests {

    /// Frame steps on a real variable-frame-rate movie (`HS2-6XMK1J`, docs/06 §6.10), end to end:
    /// an H.264 movie written like a screen recording (a frame only when something changes, the
    /// first one at a non-zero source time, so the track has an edit list) is read by
    /// `VideoTrim.frameGrid`, and scripted arrow keys in an `EditorSession` land on its real frames.
    @Suite(.timeLimit(.minutes(2)))
    struct VariableFrameRateMovieTests {
        typealias Session = VideoTrimSessionTests

        /// Frame starts (ms): red until 1000, blue from there; the movie ends at 2000.
        static let frameStarts = [0, 100, 150, 400, 420, 1000, 1500, 1530, 1560, 1900]

        /// Writes the variable-rate movie, its clock starting at 5 s, and returns its duration.
        static func writeMovie(to url: URL, starts: [Int] = frameStarts) async throws -> Int {
            let writer = try VideoFileWriter(url: url, width: 160, height: 90, framesPerSecond: 30)
            let red = try #require(VideoFileWriter.pixelBuffer(from: Session.Fixture.solid(1, 0, 0), width: 160, height: 90))
            let blue = try #require(VideoFileWriter.pixelBuffer(from: Session.Fixture.solid(0, 0, 1), width: 160, height: 90))
            let clock = 3000 // 5 s at timescale 600
            for start in starts {
                let time = CMTime(value: CMTimeValue(clock + start * 6 / 10), timescale: 600)
                while !writer.append(start < 1000 ? red : blue, at: time) {
                    try await Task.sleep(for: .milliseconds(5))
                    if writer.framesDropped > 2000 { throw VideoWriterError.failed("encoder never became ready") }
                }
            }
            return try await writer.finish(at: CMTime(value: CMTimeValue(clock + 1200), timescale: 600))
        }

        @Test func readsTheRealFrameTimes() async throws {
            let base = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let variable = base.appendingPathComponent("variable.mov")
            let duration = try await Self.writeMovie(to: variable)
            #expect(duration == 2000)
            #expect(VideoTrim.frameGrid(of: variable) == .samples(Self.frameStarts + [2000]))

            // The same writer at a steady 10 fps keeps the constant grid.
            let steady = base.appendingPathComponent("steady.mov")
            _ = try await Self.writeMovie(to: steady, starts: Array(stride(from: 0, to: 2000, by: 100)))
            let grid = try #require(VideoTrim.frameGrid(of: steady))
            #expect(grid.time(from: 0, frames: 1) == 100 && grid.time(from: 1950, frames: 1) == 2000, "\(grid)")

            #expect(VideoTrim.frameGrid(of: base.appendingPathComponent("missing.mov")) == nil)
        }

        @Test func arrowKeysStepTheRealFramesOfAVariableRateMovie() async throws {
            let base = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let movie = base.appendingPathComponent("source.mov")
            let duration = try await Self.writeMovie(to: movie)
            let store = ReviewDraftStore(root: base.appendingPathComponent("Drafts"))
            let draft = try store.add(DraftCapture(
                fileURL: movie, kind: .video, pixelWidth: 160, pixelHeight: 90, durationMs: duration,
                capturedAt: Date(timeIntervalSince1970: 0), context: CaptureContext()
            )).draft
            let session = try EditorSession(store: store, directory: draft.directory)
            let id = try #require(session.editor.currentMediaId)
            #expect(session.editor.frameGrid(of: id) == .samples(Self.frameStarts + [2000]), "read when the session opens")

            try EditorScript.parse(Data(#"""
            {"steps": [{"op": "time", "ms": 700}, {"op": "arrow-key", "key": "left"}]}
            """#.utf8)).run(on: session)
            #expect(session.editor.currentTimeMs == 420, "back to the start of the frame showing")
            #expect(try Session.color(session.displayImage(id)) == "red")
            try EditorScript.parse(Data(#"{"steps": [{"op": "arrow-key", "key": "right"}]}"#.utf8)).run(on: session)
            #expect(session.editor.currentTimeMs == 1000, "the next real frame, 580 ms later")
            #expect(try Session.color(session.displayImage(id)) == "blue")

            let messages = try EditorScript.parse(Data(#"""
            {"steps": [
              {"op": "timeline-drag", "handle": "trim-end", "ms": [2000]},
              {"op": "arrow-key", "key": "left"}, {"op": "arrow-key", "key": "left", "shift": true}
            ]}
            """#.utf8)).run(on: session)
            #expect(messages.last == "Trimmed to 0.1 s.", "1900, then ten frames back: clamped to the shortest clip")
            #expect(DraftEdits.load(from: draft.directory).trims["capture-1.mov"] == TimeRange(startMs: 0, endMs: 100))
        }
    }
}
