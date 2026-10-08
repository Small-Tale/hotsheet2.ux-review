import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import UXReviewKit

extension EncodingTests {

    /// Frame steps on real variable-frame-rate movies (`HS2-BADS0F`, docs/06 §6.10), end to end:
    /// H.264 movies written like screen recordings (a frame only when something changes) step on a
    /// uniform grid at their expected rate. `VideoTrim.frameRate` reads the rate UX Review's writer
    /// stores, or works it out from another writer's sample table, and scripted arrow keys in an
    /// `EditorSession` step one expected frame at a time across still stretches.
    @Suite(.timeLimit(.minutes(2)))
    struct VariableFrameRateMovieTests {
        typealias Session = VideoTrimSessionTests

        /// Frame starts (ms): red until 1000, blue from there; the movie ends at 2000.
        static let frameStarts = [0, 100, 150, 400, 420, 1000, 1500, 1530, 1560, 1900]

        /// Writes the variable-rate movie with `VideoFileWriter` (which records `framesPerSecond`),
        /// its clock starting at 5 s, and returns its duration.
        static func writeMovie(to url: URL, starts: [Int] = frameStarts, framesPerSecond: Int = 30) async throws -> Int {
            let writer = try VideoFileWriter(url: url, width: 160, height: 90, framesPerSecond: framesPerSecond)
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

        /// Writes frames at `startsMs` with a plain `AVAssetWriter` (no recorded rate, like another
        /// app's screen recording), on a host-like clock starting at 5 s, ending at `endMs`.
        static func writePlainMovie(to url: URL, startsMs: [Double], endMs: Double) async throws {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            #expect(writer.startWriting())
            func time(_ millis: Double) -> CMTime { CMTime(
                value: CMTimeValue(((5000 + millis) * 1_000_000).rounded()),
                timescale: 1_000_000_000
            ) }
            writer.startSession(atSourceTime: time(startsMs[0]))
            let frame = try #require(VideoFileWriter.pixelBuffer(from: Session.Fixture.solid(0, 1, 0), width: 160, height: 90))
            for start in startsMs + [endMs] {
                for _ in 0 ..< 400 where !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(adaptor.append(frame, withPresentationTime: time(start)))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: time(endMs))
            await writer.finishWriting()
            #expect(writer.status == .completed)
        }

        @Test func readsTheExpectedRate() async throws {
            let base = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let variable = base.appendingPathComponent("variable.mov")
            let length = try await Self.writeMovie(to: variable)
            #expect(length == 2000)
            #expect(VideoTrim.frameRate(of: variable) == 30, "the rate the recording was made for")
            let steady = base.appendingPathComponent("steady.mov")
            _ = try await Self.writeMovie(to: steady, starts: Array(stride(from: 0, to: 2000, by: 100)), framesPerSecond: 10)
            #expect(VideoTrim.frameRate(of: steady) == 10)

            // Another app's screen recording, capped at 30 fps: jittery bursts, then still stretches.
            let screen = FrameGridTests.screenRecording(fps: 30)
            let other = base.appendingPathComponent("other.mov")
            try await Self.writePlainMovie(to: other, startsMs: screen.times, endMs: Double(screen.durationMs))
            #expect(VideoTrim.frameRate(of: other) == 30, "the interval, snapped to a standard rate")
            let constant = base.appendingPathComponent("constant.mov")
            try await Self.writePlainMovie(to: constant, startsMs: (0 ..< 25).map { Double($0) * 40 }, endMs: 1000)
            let rate = try #require(VideoTrim.frameRate(of: constant))
            #expect(abs(rate - 25) < 0.01, "the nominal rate of a constant-rate movie: \(rate)")

            #expect(VideoTrim.frameRate(of: base.appendingPathComponent("missing.mov")) == nil)
        }

        @Test func arrowKeysStepExpectedFramesOfAVariableRateMovie() async throws {
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
            #expect(session.editor.frameRate(of: id) == 30, "read when the session opens")

            try EditorScript.parse(Data(#"""
            {"steps": [{"op": "time", "ms": 700}, {"op": "arrow-key", "key": "left"}]}
            """#.utf8)).run(on: session)
            #expect(session.editor.currentTimeMs == 667, "one 30 fps frame back, inside a still stretch")
            #expect(try Session.color(session.displayImage(id)) == "red")
            try EditorScript.parse(Data(#"{"steps": [{"op": "arrow-key", "key": "right", "shift": true}]}"#.utf8)).run(on: session)
            #expect(session.editor.currentTimeMs == 1000, "ten frames: 1/3 s, not ten recorded frames")
            #expect(try Session.color(session.displayImage(id)) == "blue")

            let messages = try EditorScript.parse(Data(#"""
            {"steps": [
              {"op": "timeline-drag", "handle": "trim-end", "ms": [2000]},
              {"op": "arrow-key", "key": "left"}, {"op": "arrow-key", "key": "left", "shift": true}
            ]}
            """#.utf8)).run(on: session)
            #expect(messages.last == "Trimmed to 1.6 s.", "eleven 30 fps frames back from 2000: 1634")
            #expect(DraftEdits.load(from: draft.directory).trims["capture-1.mov"] == TimeRange(startMs: 0, endMs: 1634))
        }
    }
}
