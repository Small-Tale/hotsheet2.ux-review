import Foundation

/// The uniform frame grid ← / → frame steps use: frames every 1000 / fps ms of the base movie,
/// at the movie's *expected* frame rate. Spec: docs/06-annotation-editor.md §6.10.
///
/// A variable-frame-rate movie (screen recordings only get a frame when something changes; some
/// imports) still steps at its intended rate, not through its real samples, so a still stretch
/// doesn't make one step jump seconds (`HS2-BADS0F`). `expectedRate` works out that rate.
public struct FrameGrid: Equatable, Sendable {
    /// Frames per second.
    public var fps: Double

    public init(fps: Double) { self.fps = fps }

    /// Whether `fps` is a usable rate (finite, at least 1).
    public var isValid: Bool { fps.isFinite && fps >= 1 }

    /// Sample times further than this from the nominal grid make a movie variable-rate.
    static let constantTolerance = 0.5
    /// Common video frame rates an estimated rate snaps to.
    static let standardRates = [10, 12, 15, 20, 24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 48, 50, 60000.0 / 1001, 60, 90, 100, 120]
    /// How close (as a ratio) an estimate must be to a standard rate to snap to it.
    static let snapTolerance = 0.1
    /// Which gap between frames stands for the frame interval: this low percentile, so a single odd
    /// short gap doesn't set the rate.
    static let intervalPercentile = 0.1
    /// Gaps shorter than this (ms) are the same frame time, not an interval.
    static let minimumGapMs = 0.5
    /// The highest rate an estimate may give.
    static let maximumRate = 240.0

    /// The rate a movie was meant to play at, for a uniform step grid:
    /// 1. `recordedRate`: the rate UX Review's writer stored in its own recordings;
    /// 2. the nominal rate when every sample (`sampleTimesMs`, presentation times on the movie
    ///    timeline, any order, `durationMs` long; times within `minimumGapMs` count once) sits on
    ///    it: a constant-rate movie;
    /// 3. otherwise a variable-rate movie's interval: the `intervalPercentile` of the gaps between
    ///    its frames, as a rate snapped to the nearest standard rate within `snapTolerance`. Nil when
    ///    that is below the lowest standard rate (frames only seconds apart say little about the
    ///    intended rate), so the caller uses its default;
    /// 4. without two readable samples, the nominal rate (nil when unknown).
    public static func expectedRate(
        recordedRate: Double? = nil,
        sampleTimesMs: [Double]?,
        durationMs: Int?,
        nominalRate: Double?
    ) -> Double? {
        if let recordedRate, FrameGrid(fps: recordedRate).isValid { return recordedRate }
        let nominal = nominalRate.flatMap { FrameGrid(fps: $0).isValid ? $0 : nil }
        let end = durationMs.map(Double.init) ?? .infinity
        // Frame times within `minimumGapMs` of the previous one are the same time.
        let times = (sampleTimesMs ?? []).filter { $0.isFinite && $0 >= 0 && $0 < end }.sorted()
            .reduce(into: [Double]()) { kept, time in
                if let last = kept.last, time - last < minimumGapMs { return }
                kept.append(time)
            }
        guard times.count >= 2 else { return nominal }
        if let nominal {
            let frameMs = 1000 / nominal
            let onGrid = times.enumerated().allSatisfy { index, time in
                abs(time - Double(index) * frameMs) <= constantTolerance
            }
            if onGrid { return nominal }
        }
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.sorted()
        let interval = gaps[Int(Double(gaps.count - 1) * intervalPercentile)]
        let rate = min(1000 / interval, maximumRate)
        guard let lowest = standardRates.min(), rate >= lowest * (1 - snapTolerance) else { return nil }
        return snapped(rate)
    }

    /// `rate` snapped to the nearest standard rate within `snapTolerance`, else as it is.
    static func snapped(_ rate: Double) -> Double {
        let nearest = standardRates.min { abs(log($0 / rate)) < abs(log($1 / rate)) }
        if let nearest, abs(nearest / rate - 1) <= snapTolerance { return nearest }
        return rate
    }

    /// The first whole ms inside a frame starting at `millis`.
    static func wholeMs(_ millis: Double) -> Int { Int((millis - 1e-6).rounded(.up)) }

    /// The movie time `frames` frames from `time` (ms of the base movie): frame k starts at
    /// ⌈k · 1000 / fps⌉ ms. Forward goes to the start of a later frame; back goes to the start of
    /// the frame showing first when `time` is inside it. The grid goes on past the movie's ends
    /// (the caller clamps).
    public func time(from time: Int, frames: Int) -> Int {
        let frameMs = 1000 / fps
        func start(_ index: Int) -> Int { Self.wholeMs(Double(index) * frameMs) }
        var index = Int((Double(time) / frameMs).rounded(.down))
        while start(index + 1) <= time {
            index += 1
        }
        while start(index) > time {
            index -= 1
        }
        let target = frames > 0 || start(index) == time ? index + frames : index + frames + 1
        return start(target)
    }
}
