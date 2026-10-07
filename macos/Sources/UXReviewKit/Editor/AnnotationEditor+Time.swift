import Foundation

// Video time: the playhead, annotation time ranges, and trimming. Spec:
// docs/06-annotation-editor.md §6.10. The playhead is navigation (not undoable); time ranges and
// trims are undoable edits.
public extension AnnotationEditor {
    /// The shortest clip a trim keeps, in millis.
    static let minimumTrimMs = 100
    /// How far one playhead step moves (`,` and `.`); Shift steps `largeTimeStepMs`.
    static let timeStepMs = 100
    static let largeTimeStepMs = 1000

    /// The current video's duration as trimmed, or nil for images.
    var currentDurationMs: Int? {
        guard let item = currentMedia, item.kind == .video else { return nil }
        return item.durationMs
    }

    /// Annotations on `mediaId` that show at the playhead (images: all of them), in review order.
    func visibleAnnotations(on mediaId: String) -> [Annotation] {
        let time = mediaId == currentMediaId ? currentTimeMs : 0
        return annotations(on: mediaId).filter { $0.isVisible(atMs: time) }
    }

    /// Moves the playhead, clamped to the current video. Annotations stay selected even when they
    /// stop showing.
    mutating func setCurrentTime(_ millis: Int) {
        guard let duration = currentDurationMs else { return }
        cancelGesture()
        currentTimeMs = min(max(millis, 0), duration)
    }

    /// `,` / `.`: steps the playhead back or forward.
    mutating func stepTime(forward: Bool, large: Bool = false) {
        let step = large ? Self.largeTimeStepMs : Self.timeStepMs
        setCurrentTime(currentTimeMs + (forward ? step : -step))
    }

    /// Sets when an annotation on a video shows, clamped into the clip (`nil`: the whole clip).
    /// Endpoints in the wrong order are swapped. Refused for images.
    @discardableResult
    mutating func setTimeRange(_ range: TimeRange?, for id: String) -> Bool {
        guard let target = annotation(id), let item = media(target.mediaId), item.kind == .video else { return false }
        let clamped = range.map { range -> TimeRange in
            let duration = item.durationMs ?? Int.max
            let low = min(max(min(range.startMs, range.endMs), 0), duration)
            let high = min(max(max(range.startMs, range.endMs), 0), duration)
            return TimeRange(startMs: low, endMs: high)
        }
        return perform { snapshot in
            snapshot.document.bundle.update(id) { $0.timeRange = clamped }
        }
    }

    /// Keeps only `range` (millis into the current video as trimmed: the clip runs from `startMs` to
    /// `endMs`). `durationMs` becomes the kept length; annotation ranges move with the clip and are
    /// clamped into it, and annotations whose range lies entirely outside it are removed (undo
    /// brings them back). Trims compose. Returns false, with a message, when refused.
    @discardableResult
    mutating func trim(to range: TimeRange) -> Bool {
        guard let item = currentMedia else { return false }
        guard item.kind == .video, let duration = item.durationMs else {
            message = "Only videos can be trimmed."
            return false
        }
        let start = min(max(range.startMs, 0), duration)
        let end = min(max(range.endMs, 0), duration)
        guard end - start >= Self.minimumTrimMs else {
            message = "A trimmed video must be at least \(Self.minimumTrimMs) ms long."
            return false
        }
        guard start > 0 || end < duration else { return false }
        let kept = end - start
        var removed = 0
        let changed = perform { snapshot in
            let previous = snapshot.document.trims[item.id]?.startMs ?? 0
            snapshot.document.trims[item.id] = TimeRange(startMs: previous + start, endMs: previous + end)
            snapshot.document.bundle.setDuration(item.id, kept)
            snapshot.document.bundle.annotations = snapshot.document.bundle.annotations.compactMap { annotation in
                guard annotation.mediaId == item.id, let range = annotation.timeRange else { return annotation }
                guard range.endMs >= start, range.startMs <= end else {
                    removed += 1
                    return nil
                }
                var moved = annotation
                moved.timeRange = TimeRange(startMs: max(range.startMs, start) - start, endMs: min(range.endMs, end) - start)
                return moved
            }
            if let selected = snapshot.selection, !snapshot.document.bundle.annotations.contains(where: { $0.id == selected }) {
                snapshot.selection = nil
            }
            snapshot.timeMs = min(max(snapshot.timeMs - start, 0), kept)
            return true
        }
        guard changed else { return false }
        message = "Trimmed to \(TimeFormat.seconds(kept))."
            + (removed > 0 ? " Removed \(removed) annotation\(removed == 1 ? "" : "s") outside the trim." : "")
        return true
    }

    /// Trims away everything before the playhead.
    @discardableResult
    mutating func trimStartToPlayhead() -> Bool {
        guard let duration = currentDurationMs else { return trim(to: TimeRange(startMs: 0, endMs: 0)) }
        return trim(to: TimeRange(startMs: currentTimeMs, endMs: duration))
    }

    /// Trims away everything after the playhead.
    @discardableResult
    mutating func trimEndToPlayhead() -> Bool {
        trim(to: TimeRange(startMs: 0, endMs: currentTimeMs))
    }

    /// Restores the current video's full length from when the session opened (or its kept
    /// original), mapping annotation ranges back. Undoable.
    @discardableResult
    mutating func resetTrim() -> Bool {
        guard let item = currentMedia, let trim = document.trims[item.id], let original = originalDurations[item.id] else { return false }
        return perform { snapshot in
            snapshot.document.trims[item.id] = nil
            snapshot.document.bundle.setDuration(item.id, original)
            for index in snapshot.document.bundle.annotations.indices where snapshot.document.bundle.annotations[index].mediaId == item.id {
                guard let range = snapshot.document.bundle.annotations[index].timeRange else { continue }
                snapshot.document.bundle.annotations[index].timeRange = TimeRange(
                    startMs: range.startMs + trim.startMs, endMs: range.endMs + trim.startMs
                )
            }
            snapshot.timeMs += trim.startMs
            return true
        }
    }

    /// True when the current media is cropped or trimmed, so Restore Original applies.
    var canRestoreOriginal: Bool {
        guard let id = currentMediaId else { return false }
        return document.crops[id] != nil || document.trims[id] != nil
    }

    /// Restore Original: resets the current image's crop or the current video's trim.
    @discardableResult
    mutating func restoreOriginal() -> Bool {
        currentMedia?.kind == .video ? resetTrim() : resetCrop()
    }
}

extension AnnotationEditor {
    /// Keeps the playhead inside the current video (0 for images).
    mutating func clampTime() {
        currentTimeMs = min(max(currentTimeMs, 0), currentDurationMs ?? 0)
    }
}

extension ReviewBundle {
    mutating func setDuration(_ mediaId: String, _ durationMs: Int) {
        guard let index = media.firstIndex(where: { $0.id == mediaId }) else { return }
        media[index].durationMs = durationMs
    }
}

/// Times as the editor shows them.
public enum TimeFormat {
    /// `m:ss.cc`, for example `0:04.25` (centiseconds, truncated).
    public static func clock(_ millis: Int) -> String {
        let millis = max(millis, 0)
        let minutes = millis / 60000
        let seconds = millis / 1000 % 60
        let centis = millis % 1000 / 10
        return String(format: "%d:%02d.%02d", minutes, seconds, centis)
    }

    /// Seconds with one decimal, for example `4.2 s`.
    public static func seconds(_ millis: Int) -> String {
        String(format: "%.1f s", Double(millis) / 1000)
    }

    /// A range for lists: `0:01.00–0:02.50`, a single time for an instant, or `Whole clip`.
    public static func range(_ range: TimeRange?) -> String {
        guard let range else { return "Whole clip" }
        return range.startMs == range.endMs ? clock(range.startMs) : "\(clock(range.startMs))–\(clock(range.endMs))"
    }
}
