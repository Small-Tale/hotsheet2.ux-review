import Foundation

/// Where a movie's frames start, for ← / → frame steps. Spec: docs/06-annotation-editor.md §6.10.
///
/// A constant-rate movie keeps the nominal grid: frame k starts at ⌈k · 1000 / fps⌉ ms. A
/// variable-frame-rate movie (screen recordings only get a frame when something changes, and
/// some imports) lists its frames' real start times instead. Times are ms of the base movie.
public enum FrameGrid: Equatable, Sendable {
    /// Frames every 1000 / fps ms from 0.
    case constant(fps: Double)
    /// Frame boundaries in whole ms, ascending and unique: 0, each later frame's start, and the
    /// movie's end (where its last frame stops), at least two of them.
    case samples([Int])

    /// Sample times further than this from the nominal grid make a movie variable-rate.
    static let constantTolerance = 0.5

    /// The grid for a movie whose video samples start at `sampleTimesMs` (presentation times on
    /// the movie timeline, any order), `durationMs` long, with `nominalRate` frames per second
    /// (nil when unknown). Samples on the nominal grid (every k-th sample at k frames) give
    /// `constant`; other times give `samples`. Nil when there are too few samples to tell, so the
    /// caller falls back to the nominal or default rate.
    public static func make(sampleTimesMs: [Double], durationMs: Int?, nominalRate: Double?) -> FrameGrid? {
        let end = durationMs.map(Double.init) ?? .infinity
        let times = sampleTimesMs.filter { $0.isFinite && $0 >= 0 && $0 < end }.sorted()
        guard times.count >= 2 else { return nil }
        if let rate = nominalRate, rate.isFinite, rate >= 1 {
            let frameMs = 1000 / rate
            let onGrid = times.enumerated().allSatisfy { index, time in
                abs(time - Double(index) * frameMs) <= constantTolerance
            }
            if onGrid { return .constant(fps: rate) }
        }
        var bounds = Set(times.map(wholeMs))
        bounds.insert(0)
        if let durationMs { bounds.insert(durationMs) }
        return .samples(bounds.sorted())
    }

    /// The first whole ms inside a frame starting at `millis`.
    static func wholeMs(_ millis: Double) -> Int { Int((millis - 1e-6).rounded(.up)) }

    /// The movie time `frames` frames from `time` (ms of the base movie). Forward goes to the
    /// start of a later frame; back goes to the start of the frame showing first when `time` is
    /// inside it. A constant grid goes on past the movie's ends (the caller clamps); a sample
    /// grid stops at its first and last boundaries.
    public func time(from time: Int, frames: Int) -> Int {
        switch self {
        case let .constant(fps):
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
        case let .samples(bounds):
            guard !bounds.isEmpty else { return time }
            // The frame showing at `time`: the last boundary at or before it (-1: before them all).
            var low = 0
            var high = bounds.count
            while low < high {
                let middle = (low + high) / 2
                if bounds[middle] <= time { low = middle + 1 } else { high = middle }
            }
            let index = low - 1
            let onBoundary = index >= 0 && bounds[index] == time
            let target = frames > 0 || onBoundary ? index + frames : index + frames + 1
            return bounds[min(max(target, 0), bounds.count - 1)]
        }
    }

    /// Frames per second: the constant rate, or a sample grid's average.
    public var averageRate: Double {
        switch self {
        case let .constant(fps):
            return fps
        case let .samples(bounds):
            guard let first = bounds.first, let last = bounds.last, last > first else { return AnnotationEditor.defaultFrameRate }
            return Double(bounds.count - 1) * 1000 / Double(last - first)
        }
    }
}
