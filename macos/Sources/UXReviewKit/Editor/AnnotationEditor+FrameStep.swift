import Foundation

/// What ← / → step frame by frame on a video: the timeline thing the reviewer used last.
/// Spec: docs/06-annotation-editor.md §6.4 and §6.10.
public enum TimelineStepTarget: Equatable, Hashable, Sendable {
    /// The scrubber: the playhead.
    case playhead
    /// The clip's in and out points.
    case trimStart
    case trimEnd
    /// An end of this annotation's time range (only while it is selected).
    case rangeStart(String)
    case rangeEnd(String)

    /// The target for a timeline handle (`annotationId` for range handles).
    init(_ handle: TimelineHandle, annotationId: String) {
        switch handle {
        case .rangeStart: self = .rangeStart(annotationId)
        case .rangeEnd: self = .rangeEnd(annotationId)
        case .trimStart: self = .trimStart
        case .trimEnd: self = .trimEnd
        }
    }
}

// Frame stepping with ← / → (⇧: 10 frames). The arrows act on what the reviewer used last:
// - a timeline target (the scrubber, a trim end, or the selected annotation's range end) steps
//   frame by frame;
// - after a canvas press, a selection, or a new shape, they nudge the selected shape, as on images;
// - with nothing selected on a video they step the playhead.
// A range target whose annotation is gone, deselected, or no longer ranged falls back to the
// playhead. Trim and range steps are undoable, and consecutive steps of the same end coalesce
// into one undo step, like nudges; playhead steps are navigation.
public extension AnnotationEditor {
    /// Frames per second when a movie's rate is unknown.
    static let defaultFrameRate = 30.0
    /// How many frames ⇧← / ⇧→ step.
    static let largeFrameStep = 10

    /// The frame grid frame steps use for `mediaId`: its movie's expected rate, else
    /// `defaultFrameRate`.
    func frameGrid(of mediaId: String) -> FrameGrid {
        frameGrids[mediaId] ?? FrameGrid(fps: Self.defaultFrameRate)
    }

    /// The frame rate frame steps use for `mediaId`.
    func frameRate(of mediaId: String) -> Double { frameGrid(of: mediaId).fps }

    /// Records a video's expected frame rate (from its movie, `FrameGrid.expectedRate`); nil or a
    /// nonsense rate means unknown.
    mutating func setFrameRate(_ rate: Double?, for mediaId: String) {
        let grid = rate.map(FrameGrid.init(fps:))
        frameGrids[mediaId] = grid?.isValid == true ? grid : nil
    }

    /// What ← / → step on the current media, resolved from `timelineTarget`: nil when they move
    /// the selected shape instead (and always on an image).
    var frameStepTarget: TimelineStepTarget? {
        guard let item = currentMedia, item.kind == .video, item.durationMs != nil else { return nil }
        switch timelineTarget {
        case nil:
            return selection == nil ? .playhead : nil
        case let .rangeStart(id), let .rangeEnd(id):
            guard selection == id, let annotation = annotation(id), annotation.mediaId == item.id, annotation.timeRange != nil else {
                return .playhead
            }
            return timelineTarget
        case .playhead, .trimStart, .trimEnd:
            return timelineTarget
        }
    }

    /// ← / → on the canvas: a frame step of `frameStepTarget` (⇧: 10 frames), otherwise a nudge of
    /// the selection (⇧: 10 px). False when nothing changed.
    @discardableResult
    mutating func arrowKey(forward: Bool, large: Bool = false) -> Bool {
        if let target = frameStepTarget {
            let frames = large ? Self.largeFrameStep : 1
            return stepFrames(forward ? frames : -frames, target: target)
        }
        let pixels: Double = large ? 10 : 1
        return nudgeSelection(dx: forward ? pixels : -pixels, dy: 0)
    }

    /// Moves `target` by `frames` frames (negative: back), snapped to the movie's frames and kept
    /// within the clip and its rules: trim ends keep the minimum clip and stay inside the original
    /// (stepping outward brings trimmed time back); range ends stay inside the clip and drag the
    /// other end along. The playhead follows, showing the frame at the moved end, as on drags.
    /// `target` becomes the timeline target. False when nothing moved.
    @discardableResult
    mutating func stepFrames(_ frames: Int, target: TimelineStepTarget) -> Bool {
        cancelGesture()
        guard let item = currentMedia, item.kind == .video, let duration = item.durationMs, frames != 0 else { return false }
        timelineTarget = target
        switch target {
        case .playhead:
            let before = currentTimeMs
            setCurrentTime(frameTime(from: currentTimeMs, frames: frames, of: item.id))
            coalesceKey = nil
            return currentTimeMs != before
        case .trimStart, .trimEnd:
            // In Trim mode the handle moves; nothing is applied until Trim (HS2-ECE7WY).
            if trimMode != nil { return stepTrimModeEnd(frames, start: target == .trimStart) }
            let base = document.trims[item.id] ?? TimeRange(startMs: 0, endMs: duration)
            let original = max(originalDurations[item.id] ?? 0, base.endMs)
            var start = 0
            var end = duration
            if target == .trimStart {
                start = min(max(frameTime(from: 0, frames: frames, of: item.id), -base.startMs), duration - Self.minimumTrimMs)
            } else {
                end = max(min(frameTime(from: duration, frames: frames, of: item.id), original - base.startMs), Self.minimumTrimMs)
            }
            guard end - start >= Self.minimumTrimMs,
                  applyTrim(item, startMs: start, endMs: end, coalescing: .frameStep(target)) else { return false }
            setPlayhead(target == .trimStart ? 0 : end - start)
            return true
        case let .rangeStart(id), let .rangeEnd(id):
            guard let range = annotation(id)?.timeRange else { return false }
            let isStart = target == .rangeStart(id)
            let handle: TimelineHandle = isStart ? .rangeStart : .rangeEnd
            let time = min(max(frameTime(from: isStart ? range.startMs : range.endMs, frames: frames, of: item.id), 0), duration)
            guard setRangeEnd(handle, toMs: time, for: id, coalescing: .frameStep(target)) else { return false }
            setPlayhead(time)
            return true
        }
    }

    /// The time `frames` frames from `millis` (clip as trimmed) on `mediaId`'s movie, not clamped.
    /// Frames sit on the movie's uniform grid at its expected rate (`FrameGrid`), so a trimmed clip
    /// keeps it: frame k starts at ⌈k · 1000 / fps⌉ ms of the base movie, even where a
    /// variable-rate movie recorded no frame. Forward goes to the start of a later frame; back goes
    /// to the start of the frame showing first when `millis` is inside it.
    func frameTime(from millis: Int, frames: Int, of mediaId: String) -> Int {
        let offset = document.trims[mediaId]?.startMs ?? 0
        return frameGrid(of: mediaId).time(from: offset + millis, frames: frames) - offset
    }
}
