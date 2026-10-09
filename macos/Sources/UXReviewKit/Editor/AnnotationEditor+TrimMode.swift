import Foundation

/// Trim mode (`HS2-ECE7WY`, docs/06 §6.10), like QuickTime's trim bar. **Trim** enters it for the
/// current video: the timeline shows the whole original movie with the kept part between two
/// handles, and only the handles, play, and the scrubber work. **Trim** applies the new range as
/// one undo step; **Cancel** (or Esc, ⌘Z, showing another capture) leaves everything as it was.
///
/// While the mode is on, the working document is the movie untrimmed (so the canvas, the player,
/// and the timeline show the whole original), and `persistentDocument` is the one from before
/// the mode, which saving writes.
public struct TrimMode: Equatable, Sendable {
    public let mediaId: String
    /// The part kept, in ms of the whole original movie.
    public internal(set) var range: TimeRange
    /// The original movie's length.
    public let originalMs: Int
    /// The kept part when the mode began.
    public let startRange: TimeRange
    /// The editor's state before the mode, restored on Cancel and before Trim applies.
    let base: AnnotationEditor.Snapshot
}

public extension AnnotationEditor {
    /// The document saving writes: the one from before Trim mode while it is on.
    var persistentDocument: EditorDocument { trimMode?.base.document ?? document }

    /// True when the current media is a video that Trim mode can start on.
    var canTrim: Bool { trimMode == nil && currentMedia?.kind == .video && currentDurationMs != nil }

    /// Starts Trim mode on the current video. The playhead stays on the same frame of the
    /// original. Returns false for images, or when the mode is already on.
    @discardableResult
    mutating func enterTrimMode() -> Bool {
        guard canTrim, let item = currentMedia, let duration = item.durationMs else { return false }
        cancelGesture()
        cancelTimelineDrag()
        let original = originalDurations[item.id] ?? duration
        let kept = document.trims[item.id] ?? TimeRange(startMs: 0, endMs: original)
        let base = snapshot
        var untrimmed = base
        Self.removeTrim(of: item.id, originalMs: original, in: &untrimmed)
        document = untrimmed.document
        currentTimeMs = untrimmed.timeMs
        clampTime()
        selection = nil
        message = nil
        trimMode = TrimMode(mediaId: item.id, range: kept, originalMs: original, startRange: kept, base: base)
        timelineTarget = .trimEnd
        return true
    }

    /// Moves the mode's start or end to `millis` (ms of the original), keeping at least
    /// `minimumTrimMs` between them, and shows the frame there.
    mutating func setTrimModeEnd(_ handle: TimelineHandle, toMs millis: Int) {
        guard var mode = trimMode, handle.isTrim else { return }
        if handle == .trimStart {
            mode.range.startMs = min(max(millis, 0), mode.range.endMs - Self.minimumTrimMs)
        } else {
            mode.range.endMs = max(min(millis, mode.originalMs), mode.range.startMs + Self.minimumTrimMs)
        }
        trimMode = mode
        timelineTarget = handle == .trimStart ? .trimStart : .trimEnd
        setCurrentTime(handle == .trimStart ? mode.range.startMs : mode.range.endMs)
    }

    /// Ends the mode, keeping its range: one undo step when it differs from before (back to the
    /// whole movie drops the trim). Returns false when the mode wasn't on.
    @discardableResult
    mutating func commitTrimMode() -> Bool {
        guard let mode = trimMode, let base = trimModeBase() else { return false }
        guard mode.range != mode.startRange, let item = media(mode.mediaId) else { return true }
        // Relative to the clip as it was trimmed before the mode (`applyTrim` takes ends outside it).
        let offset = mode.startRange.startMs
        if !applyTrim(item, startMs: mode.range.startMs - offset, endMs: mode.range.endMs - offset) { restore(base) }
        return true
    }

    /// Ends the mode, leaving everything as it was before it. Returns false when it wasn't on.
    @discardableResult
    mutating func cancelTrimMode() -> Bool {
        guard trimModeBase() != nil else { return false }
        return true
    }

    /// Clears the mode and restores the state from before it; nil when it wasn't on.
    private mutating func trimModeBase() -> Snapshot? {
        guard let mode = trimMode else { return nil }
        trimMode = nil
        restore(mode.base)
        timelineTarget = nil
        return mode.base
    }

    /// A frame step of a Trim-mode handle: moves it `frames` frames (on the movie's frame grid).
    internal mutating func stepTrimModeEnd(_ frames: Int, start: Bool) -> Bool {
        guard let mode = trimMode else { return false }
        let from = start ? mode.range.startMs : mode.range.endMs
        let handle: TimelineHandle = start ? .trimStart : .trimEnd
        setTrimModeEnd(handle, toMs: frameTime(from: from, frames: frames, of: mode.mediaId))
        return trimMode?.range != mode.range
    }
}
