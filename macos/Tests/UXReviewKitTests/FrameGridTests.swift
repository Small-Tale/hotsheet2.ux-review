import Foundation
import Testing
@testable import UXReviewKit

/// Frame grids for ← / → frame steps (docs/06-annotation-editor.md §6.10, `HS2-6XMK1J`): which
/// movies keep the constant nominal grid and which step through their real sample times, and the
/// step rule on an irregular grid (starts, ends, positions between samples, ⇧ ×10 across gaps).
struct FrameGridTests {
    /// An irregular movie: 4000 ms, frames at these starts (a burst, then long still stretches).
    static let bounds = [0, 100, 150, 400, 420, 1000, 1500, 1530, 1560, 1900, 3000, 4000]
    static let grid = FrameGrid.samples(bounds)

    // MARK: Constant or variable

    @Test func samplesOnTheNominalGridKeepTheConstantRate() {
        let tenFps = (0 ..< 20).map { Double($0) * 100 }
        #expect(FrameGrid.make(sampleTimesMs: tenFps, durationMs: 2000, nominalRate: 10) == .constant(fps: 10))
        let ntsc = (0 ..< 60).map { Double($0) * 1001 / 30 }
        #expect(FrameGrid.make(sampleTimesMs: ntsc, durationMs: 2002, nominalRate: 29.97) == .constant(fps: 29.97))
        let jitter = tenFps.enumerated().map { $1 + ($0.isMultiple(of: 2) ? 0.4 : -0.4) }
        #expect(FrameGrid.make(sampleTimesMs: jitter, durationMs: 2000, nominalRate: 10) == .constant(fps: 10), "within half a ms")
        #expect(
            FrameGrid.make(sampleTimesMs: tenFps.reversed(), durationMs: 2000, nominalRate: 10) == .constant(fps: 10),
            "decode order is not presentation order"
        )
        #expect(
            FrameGrid.make(sampleTimesMs: tenFps + [2000], durationMs: 2000, nominalRate: 10) == .constant(fps: 10),
            "a zero-length hold frame at the end is not a frame"
        )
    }

    @Test func irregularSamplesGiveTheirOwnTimes() {
        let times: [Double] = [0, 100, 150, 400, 420, 1000, 1500, 1530, 1560, 1900, 3000]
        // AVFoundation's nominal rate for such a movie is its average: no constant grid fits.
        #expect(FrameGrid.make(sampleTimesMs: times, durationMs: 4000, nominalRate: 2.75) == Self.grid)
        #expect(FrameGrid.make(sampleTimesMs: times, durationMs: 4000, nominalRate: nil) == Self.grid)
        #expect(FrameGrid.make(sampleTimesMs: times, durationMs: 4000, nominalRate: .nan) == Self.grid)
        let dropped = (0 ..< 20).filter { $0 != 7 }.map { Double($0) * 100 }
        #expect(
            FrameGrid.make(sampleTimesMs: dropped, durationMs: 2000, nominalRate: 10) == .samples(dropped.map { Int($0) } + [2000]),
            "a constant-rate movie with a dropped frame is variable"
        )
        #expect(
            FrameGrid.make(sampleTimesMs: [250, 33.3334, 66.6667], durationMs: 300, nominalRate: nil) == .samples([0, 34, 67, 250, 300]),
            "the first whole ms of each frame; time 0 always starts one"
        )
        #expect(
            FrameGrid.make(sampleTimesMs: [0, 10.2, 10.6, 20], durationMs: nil, nominalRate: nil) == .samples([0, 11, 20]),
            "frames inside one ms collapse; no end without a duration"
        )
    }

    @Test func tooFewUsableSamplesLeaveTheRateToTheCaller() {
        #expect(FrameGrid.make(sampleTimesMs: [], durationMs: 1000, nominalRate: 30) == nil)
        #expect(FrameGrid.make(sampleTimesMs: [0], durationMs: 1000, nominalRate: 30) == nil)
        #expect(FrameGrid.make(sampleTimesMs: [0, 1000, 1200, -5, .nan, .infinity], durationMs: 1000, nominalRate: nil) == nil)
    }

    // MARK: Stepping an irregular grid

    @Test func stepsGoToTheRealFrameStarts() {
        let grid = Self.grid
        #expect(grid.time(from: 0, frames: 1) == 100)
        #expect(grid.time(from: 100, frames: 1) == 150)
        #expect(grid.time(from: 150, frames: -1) == 100)
        #expect(grid.time(from: 420, frames: 1) == 1000, "a still stretch is one frame")
        #expect(grid.time(from: 1000, frames: -1) == 420)
        // Between samples: forward to the next frame, back to the start of the one showing.
        #expect(grid.time(from: 700, frames: 1) == 1000)
        #expect(grid.time(from: 700, frames: -1) == 420)
        #expect(grid.time(from: 999, frames: -2) == 400)
        #expect(grid.time(from: 1001, frames: -1) == 1000)
        // ⇧: 10 frames across the irregular gaps.
        #expect(grid.time(from: 0, frames: 10) == 3000)
        #expect(grid.time(from: 3500, frames: -10) == 100, "back from inside a frame: its start counts as one")
        #expect(grid.time(from: 1530, frames: -10) == 0, "clamped at the first frame")
        #expect(grid.time(from: 2000, frames: 10) == 4000, "clamped at the movie end")
    }

    @Test func theEndsStopTheSteps() {
        let grid = Self.grid
        #expect(grid.time(from: 0, frames: -1) == 0)
        #expect(grid.time(from: 4000, frames: 1) == 4000)
        #expect(grid.time(from: 3999, frames: 1) == 4000)
        #expect(grid.time(from: 4000, frames: -1) == 3000)
        #expect(grid.time(from: 5000, frames: -1) == 4000, "past the end: back to the end first")
        #expect(grid.time(from: -50, frames: 1) == 0, "before the start: forward to the first frame")
        #expect(grid.time(from: -50, frames: -1) == 0)
        #expect(FrameGrid.samples([]).time(from: 70, frames: 1) == 70, "a malformed empty grid moves nothing")
    }

    @Test func theConstantGridIsTheNominalRule() {
        let grid = FrameGrid.constant(fps: 30)
        #expect(grid.time(from: 0, frames: 1) == 34)
        #expect(grid.time(from: 33, frames: 1) == 34)
        #expect(grid.time(from: 50, frames: -1) == 34)
        #expect(grid.time(from: 0, frames: -1) == -33, "a constant grid goes on past the start; callers clamp")
        #expect(grid.averageRate == 30)
        #expect(Self.grid.averageRate == 2.75, "11 frames in 4 s")
        #expect(FrameGrid.samples([5]).averageRate == AnnotationEditor.defaultFrameRate)
    }
}

/// The editor on a variable-frame-rate movie (`HS2-6XMK1J`): the same 4000 ms clip as
/// `FrameStepTests`, with `FrameGridTests.bounds` for frames. Walks the playhead, trim ends, and
/// range ends across irregular gaps, trimmed clips, and grids replaced or dropped midway.
struct VariableFrameStepTests {
    typealias Clip = VideoTimeTests

    static func editor(select: Bool = false) -> AnnotationEditor {
        var editor = FrameStepTests.editor(select: select, fps: nil)
        editor.setFrameGrid(FrameGridTests.grid, for: "v1")
        return editor
    }

    @Test func malformedGridsFallBackTo30Fps() {
        var editor = Self.editor()
        #expect(editor.frameGrid(of: "v1") == FrameGridTests.grid)
        for bad in [FrameGrid.samples([]), .samples([0]), .samples([0, 200, 100]), .samples([0, 100, 100]), .constant(fps: 0)] {
            editor.setFrameGrid(FrameGridTests.grid, for: "v1")
            editor.setFrameGrid(bad, for: "v1")
            #expect(editor.frameGrid(of: "v1") == .constant(fps: 30), "\(bad)")
        }
        editor.setFrameGrid(FrameGridTests.grid, for: "v1")
        editor.setFrameGrid(nil, for: "v1")
        #expect(editor.frameRate(of: "v1") == 30, "a removed movie forgets its grid")
    }

    @Test func playheadStepsThroughTheRealFrames() {
        var editor = Self.editor()
        editor.movePlayhead(to: 0)
        var visited = [0]
        while editor.arrowKey(forward: true) {
            visited.append(editor.currentTimeMs)
        }
        #expect(visited == FrameGridTests.bounds, "every frame once, then the clip end")
        editor.arrowKey(forward: false, large: true)
        #expect(editor.currentTimeMs == 100)
        editor.arrowKey(forward: false, large: true)
        #expect(editor.currentTimeMs == 0)
        editor.movePlayhead(to: 1200) // inside the frame starting at 1000
        editor.arrowKey(forward: false)
        #expect(editor.currentTimeMs == 1000)
        editor.arrowKey(forward: true, large: true)
        #expect(editor.currentTimeMs == 4000)
        #expect(!editor.canUndo)
    }

    @Test func trimEndStepsOverStillStretchesAndBackToTheWholeMovie() {
        var editor = Self.editor()
        editor.stepFrames(-1, target: .trimEnd)
        #expect(editor.document.trims["v1"] == Clip.range(0, 3000), "the last frame lasted 1 s")
        editor.stepFrames(-3, target: .trimEnd)
        #expect(editor.document.trims["v1"] == Clip.range(0, 1530), "three frames back: 1900, 1560, 1530")
        #expect(editor.currentTimeMs == 1530)
        editor.stepFrames(-10, target: .trimEnd)
        #expect(editor.currentDurationMs == 100, "clamped to the shortest clip, which is also a frame start")
        editor.stepFrames(1, target: .trimEnd)
        #expect(editor.document.trims["v1"] == Clip.range(0, 150))
        editor.stepFrames(100, target: .trimEnd)
        #expect(editor.document.trims["v1"] == nil, "back to the whole movie")
        editor.undo()
        #expect(editor.document.trims["v1"] == nil && !editor.canUndo, "one coalesced step")
    }

    @Test func aTrimmedClipKeepsTheMoviesFrames() {
        var editor = Self.editor()
        editor.trim(to: Clip.range(120, 4000)) // inside the frame starting at 100
        editor.stepFrames(1, target: .trimStart)
        #expect(editor.document.trims["v1"] == Clip.range(150, 4000))
        editor.stepFrames(1, target: .trimStart)
        #expect(editor.document.trims["v1"] == Clip.range(400, 4000))
        // Clip times are offset by the trim; the movie's frames don't move.
        #expect(editor.frameTime(from: 0, frames: 1, of: "v1") == 20, "420 ms of the movie")
        #expect(editor.frameTime(from: 0, frames: -1, of: "v1") == -250, "150 ms: before the clip")
        editor.movePlayhead(to: 300) // 700 ms of the movie
        editor.arrowKey(forward: false)
        #expect(editor.currentTimeMs == 20)
        editor.stepFrames(-10, target: .trimStart)
        #expect(editor.document.trims["v1"] == nil, "clamped at the movie start: the whole movie")
        editor.trim(to: Clip.range(1000, 1600))
        editor.stepFrames(-1, target: .trimEnd)
        #expect(editor.document.trims["v1"] == Clip.range(1000, 1560))
        editor.stepFrames(-2, target: .trimEnd)
        #expect(editor.document.trims["v1"] == Clip.range(1000, 1500), "two frames back from a frame start")
    }

    @Test func rangeEndsSnapToTheRealFrames() {
        var editor = Self.editor(select: true)
        editor.setRangeEnd(.rangeEnd, toMs: 2000, for: "a1")
        editor.arrowKey(forward: false)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 1900))
        editor.arrowKey(forward: true)
        editor.arrowKey(forward: true)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 4000), "clamped to the clip")
        editor.stepFrames(-1, target: .rangeStart("a1"))
        #expect(editor.annotation("a1")?.timeRange == Clip.range(420, 4000))
        editor.stepFrames(10, target: .rangeStart("a1"))
        #expect(editor.annotation("a1")?.timeRange == Clip.range(4000, 4000), "a start past the end drags it along")
        #expect(editor.currentTimeMs == 4000)
    }

    @Test func replacingTheGridMidwayUsesTheNewFrames() {
        var editor = Self.editor()
        editor.movePlayhead(to: 420)
        editor.arrowKey(forward: true)
        #expect(editor.currentTimeMs == 1000)
        editor.setFrameRate(10, for: "v1") // e.g. the movie was replaced by a constant-rate one
        editor.arrowKey(forward: true)
        #expect(editor.currentTimeMs == 1100)
        editor.setFrameGrid(FrameGridTests.grid, for: "v1")
        editor.arrowKey(forward: true)
        #expect(editor.currentTimeMs == 1500, "1100 is inside the frame starting at 1000")
        editor.setFrameGrid(nil, for: "v1")
        editor.arrowKey(forward: true)
        #expect(editor.currentTimeMs == 1534, "unknown: 30 fps")
        // Empty, then refilled.
        editor.setFrameGrid(.samples([]), for: "v1")
        editor.setFrameGrid(FrameGridTests.grid, for: "v1")
        editor.arrowKey(forward: false)
        #expect(editor.currentTimeMs == 1530)
    }
}
