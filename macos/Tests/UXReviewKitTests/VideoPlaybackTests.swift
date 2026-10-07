import Foundation
import Testing
@testable import UXReviewKit

/// Play/pause in the editor (docs/06-annotation-editor.md §6.10): the pure position rules, then
/// end to end with a real `AVPlayer` on the 2 s red-then-blue fixture movie.
@Suite(.timeLimit(.minutes(2)))
struct VideoPlaybackTests {
    typealias Fixture = VideoTrimSessionTests.Fixture

    @Test func startsFromThePlayheadAndRestartsFromTheEnd() {
        #expect(PlaybackRules.startPosition(0, durationMs: 2000) == 0)
        #expect(PlaybackRules.startPosition(1200, durationMs: 2000) == 1200)
        #expect(PlaybackRules.startPosition(-50, durationMs: 2000) == 0)
        #expect(PlaybackRules.startPosition(2000, durationMs: 2000) == 0)
        #expect(PlaybackRules.startPosition(1990, durationMs: 2000) == 0) // within the end tolerance
        #expect(PlaybackRules.startPosition(5000, durationMs: 2000) == 0)
        #expect(PlaybackRules.startPosition(1960, durationMs: 2000) == 1960)
    }

    @Test func mapsPlayerTimeIntoTheTrimmedClip() {
        #expect(PlaybackRules.clipPosition(mediaMs: 700, offsetMs: 200, durationMs: 1000) == 500)
        #expect(PlaybackRules.clipPosition(mediaMs: 100, offsetMs: 200, durationMs: 1000) == 0)
        #expect(PlaybackRules.clipPosition(mediaMs: 1500, offsetMs: 200, durationMs: 1000) == 1000)
        #expect(PlaybackRules.reachedEnd(970, durationMs: 1000))
        #expect(!PlaybackRules.reachedEnd(969, durationMs: 1000))
    }

    /// Runs the run loop (not callable from async tests directly).
    static func wait(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Plays for about `seconds`, polling like the editor's timer, and returns the positions seen.
    static func play(_ playback: VideoPlayback, from millis: Int, for seconds: Double) -> [Int] {
        playback.play(fromMs: millis)
        var seen: [Int] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            seen.append(playback.currentMs)
        }
        return seen
    }

    @Test func playsInRealTimeAndPausesWhereItIs() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session()
        let playback = try #require(session.playback("m1"))
        let seen = Self.play(playback, from: 0, for: 0.6)
        #expect(playback.isPlaying)
        let stopped = playback.pause()
        #expect(!playback.isPlaying)
        // Monotonic, and moving at roughly real time (generous: CI machines stall).
        #expect(seen == seen.sorted())
        #expect((150 ... 1100).contains(stopped), "stopped at \(stopped)")
        #expect(try VideoTrimSessionTests.color(playback.frame()) == "red")
        Self.wait(0.2)
        #expect(abs(playback.currentMs - stopped) <= 5, "paused playback kept moving")
    }

    @Test func stopsAtTheEndAndPlayAgainRestarts() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session()
        let playback = try #require(session.playback("m1"))
        _ = Self.play(playback, from: 1500, for: 1.2)
        #expect(!playback.isPlaying)
        #expect(playback.isAtEnd)
        #expect(playback.currentMs == 2000)
        #expect(try VideoTrimSessionTests.color(playback.frame()) == "blue")
        let again = Self.play(playback, from: playback.currentMs, for: 0.3)
        #expect(try #require(again.last) < 1000, "Play at the end restarts from the beginning")
        playback.pause()
    }

    @Test func playsTheTrimmedClipOnly() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session()
        let trimmed = session.editor.trim(to: TimeRange(startMs: 1000, endMs: 1600))
        #expect(trimmed)
        let playback = try #require(session.playback("m1"))
        #expect(playback.offsetMs == 1000)
        #expect(playback.durationMs == 600)
        _ = Self.play(playback, from: 0, for: 0.25)
        // Clip time 0 is movie time 1 s: the blue half.
        #expect(try VideoTrimSessionTests.color(playback.frame()) == "blue")
        _ = Self.play(playback, from: playback.pause(), for: 1.0)
        #expect(playback.isAtEnd)
        #expect(playback.currentMs == 600, "playback ran past the trim end")
    }

    @Test func imagesHaveNoPlayback() throws {
        let base = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ReviewDraftStore(root: base)
        let image = base.appendingPathComponent("shot.png")
        try ImageFiles.writePNG(#require(ImageFiles.testCard(width: 40, height: 30)), to: image)
        let draft = try store.add(DraftCapture(
            fileURL: image, kind: .image, pixelWidth: 40, pixelHeight: 30, capturedAt: Date(), context: CaptureContext()
        )).draft
        let session = try EditorSession(store: store, directory: draft.directory)
        #expect(session.playback("m1") == nil)
        #expect(throws: EditorScriptError.self) { try EditorScript(steps: [.play(100)]).run(on: session) }
    }

    @Test func scriptPlayMovesThePlayhead() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session()
        let script = try EditorScript.parse(Data(#"{"steps": [{"op": "time", "ms": 200}, {"op": "play", "ms": 400}]}"#.utf8))
        try script.run(on: session)
        #expect((350 ... 1300).contains(session.editor.currentTimeMs), "playhead at \(session.editor.currentTimeMs)")
        #expect(!session.editor.isDirty, "playing is navigation, not an edit")
        #expect(throws: (any Error).self) { try EditorScript.parse(Data(#"{"steps": [{"op": "play"}]}"#.utf8)) }
        #expect(throws: (any Error).self) { try EditorScript.parse(Data(#"{"steps": [{"op": "play", "ms": -1}]}"#.utf8)) }
    }
}
