import Foundation

/// How the editor's media changed when it caught up with the draft on disk.
public struct MediaChanges: Equatable, Sendable {
    /// Media captured into the draft since the editor last looked, in disk order.
    public var added: [String] = []
    /// Media removed from the draft (for example in the review session), in the editor's order.
    public var removed: [String] = []

    public init(added: [String] = [], removed: [String] = []) {
        self.added = added
        self.removed = removed
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

// Keeping the editor in step with the draft on disk while it is open: captures are added and
// removed underneath it (the menu bar, drops, the review session). Spec: docs/06 §6.7.
public extension AnnotationEditor {
    /// Brings the editor's media in line with `disk`: drops media that is no longer in the draft
    /// (`dropMedia`), then adds media captured meanwhile (`mergeMedia`). A media item counts as
    /// the same only when its id, filename, and capture time all match: removing the last
    /// capture and capturing again reuses both its id and its filename, and that is a removal
    /// plus an addition.
    @discardableResult
    mutating func syncMedia(with disk: ReviewBundle) -> MediaChanges {
        cancelTrimMode()
        func identity(_ item: MediaItem) -> String { "\(item.id)|\(item.capturedAt.timeIntervalSince1970)|\(item.filename)" }
        let onDisk = Set(disk.media.map(identity))
        let gone = bundle.media.filter { !onDisk.contains(identity($0)) }.map(\.id)
        let removed = dropMedia(Set(gone))
        return MediaChanges(added: mergeMedia(from: disk), removed: removed)
    }

    /// Forgets media removed from the draft: the items, every annotation on them, their crops and
    /// trims, in the document, the saved state, and the undo/redo history. Undo steps that only
    /// changed removed media become no-ops and are dropped, so undo never brings a removed capture
    /// or its annotations back. A running gesture or timeline drag is cancelled first. When the
    /// current media goes, the editor shows the next remaining one (else the previous, else
    /// nothing). Returns the ids that were removed.
    @discardableResult
    mutating func dropMedia(_ ids: Set<String>) -> [String] {
        let order = bundle.media.map(\.id)
        let removed = order.filter(ids.contains)
        guard !removed.isEmpty else { return [] }
        cancelGesture()
        func drop(_ target: inout EditorDocument) {
            target.bundle.media.removeAll { ids.contains($0.id) }
            target.bundle.annotations.removeAll { ids.contains($0.mediaId) }
            for id in ids {
                target.crops[id] = nil
                target.trims[id] = nil
            }
        }
        drop(&document)
        drop(&savedDocument)
        for index in undoStack.indices {
            drop(&undoStack[index].document)
        }
        for index in redoStack.indices {
            drop(&redoStack[index].document)
        }
        collapseHistory()
        for id in removed {
            originalSizes[id] = nil
            originalDurations[id] = nil
        }
        if let id = selection, annotation(id) == nil { selection = nil }
        if let current = currentMediaId, ids.contains(current) {
            let index = order.firstIndex(of: current) ?? 0
            let after = order[index...].first { media($0) != nil }
            let before = order[..<index].last { media($0) != nil }
            currentMediaId = after ?? before
            selection = nil
            currentTimeMs = 0
        }
        mediaSelection.prune(to: bundle.media.map(\.id))
        coalesceKey = nil
        message = nil
        return removed
    }

    // MARK: Selecting several captures (docs/06 §6.7.2)

    /// The captures selected in the media strip, in strip order. It always holds the current
    /// capture (when there is one), which the canvas shows.
    var selectedMediaIds: [String] {
        mediaSelection.selected(order: bundle.media.map(\.id), current: currentMediaId)
    }

    /// A click on a thumbnail (`.toggle` for ⌘-click, `.extend` for ⇧-click). The canvas then
    /// shows the selection's primary capture, as a plain `show(mediaId:)` would.
    mutating func clickMedia(_ id: String, _ click: MediaSelection.Click) {
        guard media(id) != nil else { return }
        mediaSelection.click(id, click, order: bundle.media.map(\.id), current: currentMediaId)
        if let primary = mediaSelection.primary { show(mediaId: primary) }
    }

    /// What removing from thumbnail `id` acts on: the selection when `id` is in it, else `id`
    /// alone. nil (Edit menu, ⌘⌫) means the selection.
    func mediaToRemove(from id: String? = nil) -> [String] {
        mediaSelection.removalTargets(for: id, order: bundle.media.map(\.id), current: currentMediaId)
    }

    /// Drops history entries that no longer change anything (their document equals the next
    /// state's), so every undo and redo still does something visible.
    private mutating func collapseHistory() {
        var undo: [Snapshot] = []
        for (index, entry) in undoStack.enumerated() {
            let next = index + 1 < undoStack.count ? undoStack[index + 1].document : document
            if entry.document != next { undo.append(entry) }
        }
        undoStack = undo
        // Redo pops from the end, so the state after the current one is the last entry.
        var redo: [Snapshot] = []
        var previous = document
        for entry in redoStack.reversed() where entry.document != previous {
            redo.append(entry)
            previous = entry.document
        }
        redoStack = redo.reversed()
    }
}

public extension AnnotationEditor {
    /// Adds media captured while the editor is open (by `filename`, keeping the editor's own
    /// order). Undo history and the saved state learn about them too, so undo never drops a
    /// capture. Returns the ids that were added.
    @discardableResult
    mutating func mergeMedia(from disk: ReviewBundle) -> [String] {
        cancelTrimMode()
        let known = Set(bundle.media.map(\.filename))
        let added = disk.media.filter { !known.contains($0.filename) && media($0.id) == nil }
        guard !added.isEmpty else { return [] }
        func merge(_ target: inout EditorDocument) { target.bundle.media += added }
        merge(&document)
        merge(&savedDocument)
        for index in undoStack.indices {
            merge(&undoStack[index].document)
        }
        for index in redoStack.indices {
            merge(&redoStack[index].document)
        }
        if var base = gestureBase {
            merge(&base.document)
            gestureBase = base
        }
        for item in added {
            originalSizes[item.id] = Self.size(of: item)
            if let duration = item.durationMs { originalDurations[item.id] = duration }
        }
        if currentMediaId == nil { currentMediaId = added.first?.id }
        return added.map(\.id)
    }
}
