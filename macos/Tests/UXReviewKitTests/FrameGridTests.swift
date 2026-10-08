import Foundation
import Testing
@testable import UXReviewKit

/// Frame grids for ← / → frame steps (docs/06-annotation-editor.md §6.10, `HS2-BADS0F`): every
/// movie steps on a uniform grid at its expected rate. Covers how that rate is worked out (a
/// recorded rate, a constant nominal rate, a variable-rate movie's snapped interval, fallbacks),
/// and the uniform step rule.
struct FrameGridTests {
    /// An irregular movie: 4000 ms, frames at these starts (a burst, then long still stretches).
    static let irregular: [Double] = [0, 100, 150, 400, 420, 1000, 1500, 1530, 1560, 1900, 3000]

    /// A screen recording capped at `fps`: bursts of frames one interval apart (± clock jitter of
    /// up to `jitter` ms), separated by still stretches of 1.5 s. Ends after the last frame.
    static func screenRecording(fps: Double, bursts: Int = 4, jitter: Double = 1.7) -> (times: [Double], durationMs: Int) {
        var times: [Double] = []
        var time = 0.0
        for burst in 0 ..< bursts {
            for frame in 0 ..< 8 {
                times.append(time)
                let wobble = Double((burst * 8 + frame) % 3 - 1) * jitter
                time += 1000 / fps + wobble
            }
            time += 1500
        }
        return (times, Int(time.rounded(.up)))
    }

    static func rate(_ times: [Double], _ durationMs: Int?, nominal: Double?, recorded: Double? = nil) -> Double? {
        FrameGrid.expectedRate(recordedRate: recorded, sampleTimesMs: times, durationMs: durationMs, nominalRate: nominal)
    }

    // MARK: Expected rate

    @Test func aRecordedRateWins() {
        let screen = Self.screenRecording(fps: 30)
        #expect(Self.rate(screen.times, screen.durationMs, nominal: 4.5, recorded: 30) == 30)
        #expect(Self.rate([], nil, nominal: nil, recorded: 10) == 10, "even without readable samples")
        #expect(Self.rate(screen.times, screen.durationMs, nominal: 4.5, recorded: 0) == 30, "a nonsense recorded rate is ignored")
        #expect(Self.rate(screen.times, screen.durationMs, nominal: 4.5, recorded: .nan) == 30)
    }

    @Test func samplesOnTheNominalGridKeepTheNominalRate() {
        let tenFps = (0 ..< 20).map { Double($0) * 100 }
        #expect(Self.rate(tenFps, 2000, nominal: 10) == 10)
        let ntsc = (0 ..< 60).map { Double($0) * 1001 / 30 }
        #expect(Self.rate(ntsc, 2002, nominal: 29.97) == 29.97, "a constant rate is kept exactly, not snapped")
        let fiveFps = (0 ..< 10).map { Double($0) * 200 }
        #expect(Self.rate(fiveFps, 2000, nominal: 5) == 5, "a slow constant rate is real")
        let jitter = tenFps.enumerated().map { $1 + ($0.isMultiple(of: 2) ? 0.4 : -0.4) }
        #expect(Self.rate(jitter, 2000, nominal: 10) == 10, "within half a ms")
        #expect(Self.rate(tenFps.reversed(), 2000, nominal: 10) == 10, "decode order is not presentation order")
        #expect(Self.rate(tenFps + [2000], 2000, nominal: 10) == 10, "a zero-length hold frame at the end is not a frame")
    }

    @Test func variableRateMoviesUseTheirIntendedRate() {
        // Screen recordings: AVFoundation's nominal rate is the average, far below the cap.
        let thirty = Self.screenRecording(fps: 30)
        #expect(Self.rate(thirty.times, thirty.durationMs, nominal: 4.5) == 30, "31.6 fps of jittery gaps snaps to 30")
        let sixty = Self.screenRecording(fps: 60, jitter: 0.5)
        #expect(Self.rate(sixty.times, sixty.durationMs, nominal: 8) == 60)
        #expect(Self.rate(thirty.times, thirty.durationMs, nominal: nil) == 30, "no nominal rate needed")
        // A constant-rate movie with a dropped frame is variable, at its own rate.
        let dropped = (0 ..< 20).filter { $0 != 7 }.map { Double($0) * 100 }
        #expect(Self.rate(dropped, 2000, nominal: 9.5) == 10)
        // An odd short gap (a duplicate-ish frame) among many doesn't set the rate.
        var outlier = (0 ..< 30).map { Double($0) * 1000 / 30 }
        outlier.append(500 + 5)
        #expect(Self.rate(outlier, 1000, nominal: 31) == 30)
        // The shortest gaps of the irregular movie are 20 and 30 ms: 50 fps.
        #expect(Self.rate(Self.irregular, 4000, nominal: 2.75) == 50)
        #expect(Self.rate([0, 41.67, 83.33, 2000], 3000, nominal: 1.3) == 24, "within 10 % of 24")
        #expect(
            Self.rate([0, 27, 54, 2000], 3000, nominal: 1.3).map { abs($0 - 1000 / 27) < 1e-9 } == true,
            "37 fps: no standard rate is near"
        )
        #expect(Self.rate([0, 1, 2, 3], 10, nominal: nil) == 240, "capped")
    }

    @Test func framesOnlySecondsApartLeaveTheRateToTheCaller() {
        #expect(Self.rate([0, 500, 1700], 3000, nominal: 1) == nil, "2 fps is no intended rate: the editor's 30 fps")
        #expect(Self.rate([0, 1500, 3200], 4000, nominal: nil) == nil)
    }

    @Test func tooFewUsableSamplesFallBackToTheNominalRate() {
        #expect(Self.rate([], 1000, nominal: 30) == 30)
        #expect(Self.rate([0], 1000, nominal: 25) == 25)
        #expect(FrameGrid.expectedRate(sampleTimesMs: nil, durationMs: 1000, nominalRate: 24) == 24, "no sample table")
        #expect(Self.rate([0, 1000, 1200, -5, .nan, .infinity], 1000, nominal: nil) == nil)
        #expect(Self.rate([0, 0.2], nil, nominal: 12) == 12, "frames inside half a ms are one time")
        #expect(Self.rate([], 1000, nominal: 0) == nil)
        #expect(Self.rate([], 1000, nominal: .infinity) == nil)
    }

    @Test func snapping() {
        #expect(FrameGrid.snapped(31.6) == 30)
        #expect(FrameGrid.snapped(29.9) == 30000.0 / 1001, "NTSC is nearer")
        #expect(FrameGrid.snapped(23.95) == 24000.0 / 1001)
        #expect(FrameGrid.snapped(55) == 60000.0 / 1001, "the nearest by ratio")
        #expect(FrameGrid.snapped(72) == 72)
    }

    // MARK: Stepping the uniform grid

    @Test func theGridIsUniform() {
        let grid = FrameGrid(fps: 30)
        #expect(grid.time(from: 0, frames: 1) == 34)
        #expect(grid.time(from: 33, frames: 1) == 34)
        #expect(grid.time(from: 50, frames: -1) == 34)
        #expect(grid.time(from: 0, frames: -1) == -33, "the grid goes on past the start; callers clamp")
        // A still stretch of a screen recording is many grid frames, not one jump.
        #expect(grid.time(from: 420, frames: 1) == 434)
        #expect(grid.time(from: 1000, frames: 10) == 1334)
        #expect(grid.time(from: 1001, frames: -1) == 1000)
        #expect(FrameGrid(fps: 30).isValid && FrameGrid(fps: 1).isValid)
        #expect(!FrameGrid(fps: 0.5).isValid && !FrameGrid(fps: .nan).isValid && !FrameGrid(fps: .infinity).isValid)
    }
}

/// The editor stepping a variable-frame-rate movie (`HS2-BADS0F`): the same 4000 ms clip as
/// `FrameStepTests` at the expected 30 fps, whatever its real samples. Steps cross still
/// stretches one frame at a time; rates replaced, dropped, and refilled midway take effect.
struct VariableFrameStepTests {
    typealias Clip = VideoTimeTests

    static func editor(select: Bool = false) -> AnnotationEditor {
        FrameStepTests.editor(select: select, fps: 30)
    }

    @Test func playheadStepsOneExpectedFrameAtATime() {
        var editor = Self.editor()
        editor.movePlayhead(to: 420) // e.g. the last real frame before a long still stretch
        editor.arrowKey(forward: true)
        #expect(editor.currentTimeMs == 434, "the next 30 fps frame, not the next recorded one")
        editor.arrowKey(forward: true, large: true)
        #expect(editor.currentTimeMs == 767, "⇧: ten frames, 1/3 s")
        editor.arrowKey(forward: false, large: true)
        #expect(editor.currentTimeMs == 434)
        editor.arrowKey(forward: false)
        #expect(editor.currentTimeMs == 400)
        editor.movePlayhead(to: 3990)
        editor.arrowKey(forward: true, large: true)
        #expect(editor.currentTimeMs == 4000, "clamped to the clip end")
        editor.movePlayhead(to: 20)
        editor.arrowKey(forward: false, large: true)
        #expect(editor.currentTimeMs == 0, "clamped to the start")
        #expect(!editor.canUndo)
    }

    @Test func trimAndRangeEndsStepExpectedFrames() {
        var editor = Self.editor(select: true)
        editor.stepFrames(-1, target: .trimEnd)
        #expect(editor.document.trims["v1"] == Clip.range(0, 3967))
        editor.stepFrames(-10, target: .trimEnd)
        #expect(editor.document.trims["v1"] == Clip.range(0, 3634))
        editor.stepFrames(100, target: .trimEnd)
        #expect(editor.document.trims["v1"] == nil, "back to the whole movie")
        editor.setRangeEnd(.rangeEnd, toMs: 2000, for: "a1")
        editor.arrowKey(forward: false)
        #expect(editor.annotation("a1")?.timeRange == Clip.range(1000, 1967))
    }

    @Test func replacingTheRateMidwayUsesTheNewGrid() {
        var editor = Self.editor()
        editor.movePlayhead(to: 420)
        editor.arrowKey(forward: true)
        #expect(editor.currentTimeMs == 434)
        editor.setFrameRate(10, for: "v1") // e.g. the rate arrived from the movie later
        editor.arrowKey(forward: true)
        #expect(editor.currentTimeMs == 500)
        editor.setFrameRate(nil, for: "v1")
        editor.arrowKey(forward: true)
        #expect(editor.currentTimeMs == 534, "unknown: 30 fps")
        editor.setFrameRate(0, for: "v1") // empty, then refilled
        editor.setFrameRate(25, for: "v1")
        editor.arrowKey(forward: false)
        #expect(editor.currentTimeMs == 520)
        editor.arrowKey(forward: false)
        #expect(editor.currentTimeMs == 480)
    }
}
