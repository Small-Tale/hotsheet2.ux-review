import Foundation

/// A handle on the video timeline the reviewer can drag (docs/06-annotation-editor.md §6.10).
public enum TimelineHandle: String, Equatable, Sendable, CaseIterable {
    /// The selected annotation's range ends.
    case rangeStart = "range-start"
    case rangeEnd = "range-end"
    /// The clip's in and out points: dragging them inward previews a trim.
    case trimStart = "trim-start"
    case trimEnd = "trim-end"

    public var isTrim: Bool { self == .trimStart || self == .trimEnd }
}

/// A timeline drag in progress.
public struct TimelineDrag: Equatable, Sendable {
    public let handle: TimelineHandle
    /// The annotation whose range is dragged (range handles).
    public let annotationId: String?
    /// Range handles: the end that stays put. The range is always the anchor and the pointer, in
    /// order, so dragging one end past the other turns it into the other end.
    let anchorMs: Int
    /// Trim handles: the part of the clip that would be kept on release (shown, not yet applied).
    public internal(set) var pendingTrim: TimeRange?
    let base: AnnotationEditor.Snapshot
}

// Dragging range ends and trim handles on the timeline. A range drag edits live and commits one
// undo step on release; a trim drag only previews the kept part and trims on release (through
// `trim(to:)`, so with its limits and messages). Esc, undo, showing other media, or moving the
// playhead cancel the drag and restore the state from before it.
public extension AnnotationEditor {
    /// Starts dragging `handle`. Range handles need a selected annotation with a time range on the
    /// current video. False when the handle doesn't apply.
    @discardableResult
    mutating func beginTimelineDrag(_ handle: TimelineHandle) -> Bool {
        cancelGesture()
        guard let duration = currentDurationMs else { return false }
        if handle.isTrim {
            timelineDrag = TimelineDrag(
                handle: handle, annotationId: nil, anchorMs: 0,
                pendingTrim: TimeRange(startMs: 0, endMs: duration), base: snapshot
            )
            return true
        }
        guard let selected = selectedAnnotation, selected.mediaId == currentMediaId, let range = selected.timeRange else { return false }
        timelineDrag = TimelineDrag(
            handle: handle, annotationId: selected.id,
            anchorMs: handle == .rangeStart ? range.endMs : range.startMs, pendingTrim: nil, base: snapshot
        )
        return true
    }

    /// Moves the dragged handle to `millis` (clamped into the clip). The playhead follows it, so
    /// the canvas shows the frame at the handle.
    mutating func updateTimelineDrag(toMs millis: Int) {
        guard var drag = timelineDrag, let duration = currentDurationMs else { return }
        let time = min(max(millis, 0), duration)
        switch drag.handle {
        case .rangeStart, .rangeEnd:
            guard let id = drag.annotationId else { return }
            let range = TimeRange(startMs: min(drag.anchorMs, time), endMs: max(drag.anchorMs, time))
            _ = document.bundle.update(id) { $0.timeRange = range }
            currentTimeMs = time
        case .trimStart:
            let start = min(time, max(duration - Self.minimumTrimMs, 0))
            drag.pendingTrim = TimeRange(startMs: start, endMs: duration)
            currentTimeMs = start
        case .trimEnd:
            let end = max(time, min(Self.minimumTrimMs, duration))
            drag.pendingTrim = TimeRange(startMs: 0, endMs: end)
            currentTimeMs = end
        }
        timelineDrag = drag
    }

    /// Releases the handle: a changed range is one undo step; a trim is applied (or does nothing
    /// for the whole clip). The playhead stays where the handle was released.
    mutating func endTimelineDrag() {
        guard let drag = timelineDrag else { return }
        timelineDrag = nil
        if let pending = drag.pendingTrim {
            let time = currentTimeMs
            currentTimeMs = drag.base.timeMs
            guard trim(to: pending) else { return setPlayhead(time) }
            setPlayhead(time - pending.startMs)
            return
        }
        guard document != drag.base.document else { return }
        pushUndo(drag.base)
        redoStack.removeAll()
        coalesceKey = nil
        message = nil
    }

    /// Abandons the drag, restoring the range and playhead from before it.
    mutating func cancelTimelineDrag() {
        guard let drag = timelineDrag else { return }
        timelineDrag = nil
        document = drag.base.document
        selection = drag.base.selection
        currentTimeMs = drag.base.timeMs
    }

    /// Sets one end of the selected annotation's range to `millis` (typed, or Set to Playhead).
    /// Moving From past To (or To before From) drags the other end along. One undo step.
    @discardableResult
    mutating func setRangeEnd(_ handle: TimelineHandle, toMs millis: Int, for id: String) -> Bool {
        guard let range = annotation(id)?.timeRange, !handle.isTrim else { return false }
        let next = handle == .rangeStart
            ? TimeRange(startMs: millis, endMs: max(range.endMs, millis))
            : TimeRange(startMs: min(range.startMs, millis), endMs: millis)
        return setTimeRange(next, for: id)
    }
}

extension AnnotationEditor {
    /// The playhead without cancelling anything (used while finishing a drag).
    mutating func setPlayhead(_ millis: Int) {
        currentTimeMs = millis
        clampTime()
    }
}

/// What a press on the timeline grabs. Pure, so the view's hit rules are unit-tested.
public enum TimelineHitTest {
    /// How close, in points, a press must be to a handle.
    public static let tolerance: CGFloat = 6
    /// The scrubber row is above this y; the range lane is below it.
    public static let laneTop: CGFloat = 13

    /// The handle under (`x`, `y`) on a timeline `width` points wide showing `durationMs`, given
    /// the selected annotation's range (nil: none, or the whole clip). Range ends win in the
    /// range lane; the trim handles sit at the track's ends on the scrubber row. Nil: scrub.
    public static func handle(x: CGFloat, y: CGFloat, width: CGFloat, durationMs: Int, selectedRange: TimeRange?) -> TimelineHandle? {
        guard width > 0, durationMs > 0 else { return nil }
        let position = { (millis: Int) in CGFloat(millis) / CGFloat(durationMs) * width }
        if y >= laneTop, let range = selectedRange {
            let start = abs(x - position(range.startMs))
            let end = abs(x - position(range.endMs))
            if min(start, end) <= tolerance {
                // An instant: pick by side, so either end can be dragged out of it.
                if range.startMs == range.endMs { return x < position(range.startMs) ? .rangeStart : .rangeEnd }
                return start < end ? .rangeStart : .rangeEnd
            }
        }
        guard y < laneTop else { return nil }
        if x <= tolerance { return .trimStart }
        if x >= width - tolerance { return .trimEnd }
        return nil
    }
}

public extension TimeFormat {
    /// A typed time in millis: `1:02.5`, `0:01.50`, `1.5`, `1.5 s`, `1500 ms`, or `1:00:02` (hours).
    /// Nil when it doesn't read as a time, or is negative.
    static func parse(_ text: String) -> Int? {
        var string = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !string.isEmpty else { return nil }
        if string.hasSuffix("ms") {
            let number = string.dropLast(2).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), value >= 0, value.isFinite else { return nil }
            return Int(value.rounded())
        }
        if string.hasSuffix("s") { string = string.dropLast().trimmingCharacters(in: .whitespaces) }
        let parts = string.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1 ... 3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber || (isLast && $0 == ".") }),
                  let value = Double(part), value.isFinite else { return nil }
            // Minutes and seconds after a colon stay below 60.
            if index > 0, value >= 60 { return nil }
            seconds = seconds * 60 + value
        }
        return Int((seconds * 1000).rounded())
    }
}
