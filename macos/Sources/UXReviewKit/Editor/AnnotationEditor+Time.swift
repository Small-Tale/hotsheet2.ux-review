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
        return annotations(on: mediaId).filter { $0.isVisible(atMs: time) && !isOutsideEdit($0) }
    }

    /// Whether `annotation` lies entirely outside its image's crop or its movie's trim. Such an
    /// annotation stays in the draft, hidden, and comes back when the crop or trim is widened or
    /// restored; submitting leaves it out (`HS2-71SSJG`, docs/06 §6.6, §6.10).
    func isOutsideEdit(_ annotation: Annotation) -> Bool {
        guard let item = media(annotation.mediaId) else { return false }
        if document.crops[item.id] != nil, EditProjection.isOutside(annotation.shape) { return true }
        if document.trims[item.id] != nil, let range = annotation.timeRange, let duration = item.durationMs {
            return EditProjection.isOutside(range, durationMs: duration)
        }
        return false
    }

    /// The bundle as it would be submitted now: annotations clipped to each crop and trim, and
    /// those entirely outside left out (`EditProjection.clippedToMedia`).
    var submissionBundle: ReviewBundle { EditProjection.clippedToMedia(bundle).bundle }

    /// How many annotations on `mediaId` lie outside its crop or trim.
    func outsideCount(on mediaId: String) -> Int {
        annotations(on: mediaId).count(where: isOutsideEdit)
    }

    /// Moves the playhead, clamped to the current video. Annotations stay selected even when they
    /// stop showing.
    mutating func setCurrentTime(_ millis: Int) {
        guard let duration = currentDurationMs else { return }
        cancelGesture()
        currentTimeMs = min(max(millis, 0), duration)
    }

    /// The reviewer moves the playhead (scrubber, typed time, Home / End, a target button): like
    /// `setCurrentTime`, and the scrubber becomes the timeline target ← / → step (docs/06 §6.10).
    mutating func movePlayhead(to millis: Int) {
        guard currentDurationMs != nil else { return }
        setCurrentTime(millis)
        timelineTarget = .playhead
    }

    /// `,` / `.`: steps the playhead back or forward.
    mutating func stepTime(forward: Bool, large: Bool = false) {
        let step = large ? Self.largeTimeStepMs : Self.timeStepMs
        movePlayhead(to: currentTimeMs + (forward ? step : -step))
    }

    /// Sets when an annotation on a video shows, clamped into the clip (`nil`: the whole clip).
    /// Endpoints in the wrong order are swapped. Refused for images.
    @discardableResult
    mutating func setTimeRange(_ range: TimeRange?, for id: String) -> Bool {
        setTimeRange(range, for: id, coalescing: nil)
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
        return applyTrim(item, startMs: start, endMs: end)
    }

    /// Trims away everything before the playhead.
    @discardableResult
    mutating func trimStartToPlayhead() -> Bool {
        guard let duration = currentDurationMs else { return trim(to: TimeRange(startMs: 0, endMs: 0)) }
        timelineTarget = .trimStart
        return trim(to: TimeRange(startMs: currentTimeMs, endMs: duration))
    }

    /// Trims away everything after the playhead.
    @discardableResult
    mutating func trimEndToPlayhead() -> Bool {
        if currentDurationMs != nil { timelineTarget = .trimEnd }
        return trim(to: TimeRange(startMs: 0, endMs: currentTimeMs))
    }

    /// Restores the current video's full length from when the session opened (or its kept
    /// original), mapping annotation ranges back. Undoable.
    @discardableResult
    mutating func resetTrim() -> Bool {
        guard let item = currentMedia, document.trims[item.id] != nil, let original = originalDurations[item.id] else { return false }
        return perform { snapshot in
            Self.removeTrim(of: item.id, originalMs: original, in: &snapshot)
            return true
        }
    }

    /// True when the current media is cropped or trimmed, so Restore Original applies.
    var canRestoreOriginal: Bool {
        guard let id = currentMediaId else { return false }
        return document.crops[id] != nil || document.trims[id] != nil
    }

    /// Restore Original: removes the current capture's crop and, on a video, its trim too, as
    /// one undo step (docs/06 §6.6, §6.10).
    @discardableResult
    mutating func restoreOriginal() -> Bool {
        guard let item = currentMedia, canRestoreOriginal, let size = originalSize(of: item.id) else { return false }
        let duration = originalDurations[item.id]
        return perform { snapshot in
            Self.removeCrop(of: item.id, original: size, in: &snapshot)
            if let duration { Self.removeTrim(of: item.id, originalMs: duration, in: &snapshot) }
            return true
        }
    }
}

extension AnnotationEditor {
    /// Takes `mediaId`'s trim out of `snapshot`: the full length (`original` ms) back, ranges
    /// mapped back, and the playhead on the same frame.
    static func removeTrim(of mediaId: String, originalMs original: Int, in snapshot: inout Snapshot) {
        guard let trim = snapshot.document.trims[mediaId] else { return }
        snapshot.document.trims[mediaId] = nil
        snapshot.document.bundle.setDuration(mediaId, original)
        for index in snapshot.document.bundle.annotations.indices where snapshot.document.bundle.annotations[index].mediaId == mediaId {
            guard let range = snapshot.document.bundle.annotations[index].timeRange else { continue }
            snapshot.document.bundle.annotations[index].timeRange = TimeRange(
                startMs: range.startMs + trim.startMs, endMs: range.endMs + trim.startMs
            )
        }
        if snapshot.mediaId == mediaId { snapshot.timeMs += trim.startMs }
    }

    mutating func setTimeRange(_ range: TimeRange?, for id: String, coalescing key: CoalesceKey?) -> Bool {
        guard let target = annotation(id), let item = media(target.mediaId), item.kind == .video else { return false }
        let clamped = range.map { range -> TimeRange in
            let duration = item.durationMs ?? Int.max
            let low = min(max(min(range.startMs, range.endMs), 0), duration)
            let high = min(max(max(range.startMs, range.endMs), 0), duration)
            return TimeRange(startMs: low, endMs: high)
        }
        return perform(coalescing: key) { snapshot in
            snapshot.document.bundle.update(id) { $0.timeRange = clamped }
        }
    }

    /// Keeps `startMs`…`endMs` of `item` (millis into the clip as trimmed). Unlike `trim(to:)`,
    /// the ends may lie outside the clip, down to `-trim start` and up to the original's end, which
    /// brings back trimmed-away time (a frame step outward); a trim back to the whole original
    /// drops the trim. Ranges move with the clip exactly; ranges outside it are hidden, not
    /// removed, and come back when the trim is widened or restored (`HS2-71SSJG`). The playhead
    /// stays on the same frame. The caller checks the limits.
    mutating func applyTrim(_ item: MediaItem, startMs start: Int, endMs end: Int, coalescing key: CoalesceKey? = nil) -> Bool {
        guard let duration = item.durationMs else { return false }
        let previous = document.trims[item.id] ?? TimeRange(startMs: 0, endMs: duration)
        let original = max(originalDurations[item.id] ?? 0, previous.endMs)
        let base = TimeRange(startMs: previous.startMs + start, endMs: previous.startMs + end)
        guard base.startMs >= 0, base.endMs <= original, base != previous else { return false }
        let kept = end - start
        let changed = perform(coalescing: key) { snapshot in
            snapshot.document.trims[item.id] = base == TimeRange(startMs: 0, endMs: original) ? nil : base
            snapshot.document.bundle.setDuration(item.id, kept)
            for index in snapshot.document.bundle.annotations.indices where snapshot.document.bundle.annotations[index].mediaId == item.id {
                guard let range = snapshot.document.bundle.annotations[index].timeRange else { continue }
                snapshot.document.bundle.annotations[index].timeRange = TimeRange(
                    startMs: range.startMs - start,
                    endMs: range.endMs - start
                )
            }
            snapshot.timeMs = min(max(snapshot.timeMs - start, 0), kept)
            return true
        }
        guard changed else { return false }
        if let selected = selection, let annotation = annotation(selected), isOutsideEdit(annotation) { selection = nil }
        message = "Trimmed to \(TimeFormat.seconds(kept))." + outsideNote(item.id, "trim")
        return true
    }

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
