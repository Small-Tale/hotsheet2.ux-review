import CoreGraphics
import Foundation

/// The editor's tools. Shape tools draw one annotation and then return to `select`.
public enum EditorTool: String, CaseIterable, Sendable {
    case select, rect, freehand, arrow, insertion, strike, crop

    /// Single-key shortcut shown in the tool bar.
    public var shortcut: Character {
        switch self {
        case .select: "v"
        case .rect: "r"
        case .freehand: "f"
        case .arrow: "a"
        case .insertion: "i"
        case .strike: "s"
        case .crop: "c"
        }
    }

    public var label: String {
        switch self {
        case .select: "Select"
        case .rect: "Rectangle"
        case .freehand: "Freehand"
        case .arrow: "Arrow"
        case .insertion: "Insertion"
        case .strike: "Strike"
        case .crop: "Crop"
        }
    }

    public static func forShortcut(_ character: Character) -> EditorTool? {
        allCases.first { $0.shortcut == Character(character.lowercased()) }
    }
}

/// An image cropped in an earlier session: its original's size and the crop, relative to the
/// original, that produced the current file. Spec: docs/06-annotation-editor.md §6.6.
public struct PriorCrop: Codable, Equatable, Sendable {
    public var originalSize: PixelRect
    public var crop: PixelRect

    public init(originalSize: PixelRect, crop: PixelRect) {
        self.originalSize = originalSize
        self.crop = crop
    }
}

/// A movie trimmed in an earlier session: its original's duration and the trim, relative to the
/// original, that produced the current file. Spec: docs/06-annotation-editor.md §6.10.
public struct PriorTrim: Codable, Equatable, Sendable {
    public var originalDurationMs: Int
    public var trim: TimeRange

    public init(originalDurationMs: Int, trim: TimeRange) {
        self.originalDurationMs = originalDurationMs
        self.trim = trim
    }
}

/// What the editor saves: the bundle plus each image's crop and each movie's trim, relative to
/// the media as it was when the session opened (or to its kept original).
public struct EditorDocument: Equatable, Sendable {
    public var bundle: ReviewBundle
    public var crops: [String: PixelRect]
    /// The part of each trimmed movie that is kept, in ms of the session's base movie; the kept
    /// clip runs from `startMs` to `endMs` and lasts `endMs - startMs`.
    public var trims: [String: TimeRange]

    public init(bundle: ReviewBundle, crops: [String: PixelRect] = [:], trims: [String: TimeRange] = [:]) {
        self.bundle = bundle
        self.crops = crops
        self.trims = trims
    }
}

/// A pointer gesture in progress. Points are media pixels.
public enum EditorGesture: Equatable, Sendable {
    case drawing(EditorTool, points: [CGPoint])
    case moving(annotationId: String, start: CGPoint, origin: Shape)
    case resizing(annotationId: String, handle: ShapeHandle, origin: Shape)
    case cropping(start: CGPoint, current: CGPoint)
}

/// The annotation editor's state machine: document, selection, current media, tool, the
/// gesture in progress, and undo/redo. Pure value type with no UI dependency; the editor
/// window and the headless `--annotate` mode both drive it. Spec: docs/06-annotation-editor.md.
///
/// Rules:
/// - Every committed change is one undo step. A gesture commits once, when it ends; cancelling
///   it restores the state from before it began. Consecutive note edits (or nudges) of the
///   same annotation coalesce into one step.
/// - Undo and redo restore the selection and the media that was showing.
/// - Navigation (showing other media, selecting, choosing a tool) is not undoable.
public struct AnnotationEditor: Sendable {
    struct Snapshot: Equatable, Sendable {
        var document: EditorDocument
        var selection: String?
        var mediaId: String?
        var timeMs = 0
    }

    enum CoalesceKey: Equatable, Sendable {
        case note(String)
        case nudge(String)
    }

    public static let undoLimit = 200

    public internal(set) var document: EditorDocument
    public internal(set) var selection: String?
    public internal(set) var currentMediaId: String?
    public internal(set) var tool: EditorTool = .select
    public internal(set) var gesture: EditorGesture?
    /// A drag of a time-range end or trim handle on the video timeline (docs/06 §6.10).
    public internal(set) var timelineDrag: TimelineDrag?
    /// A short status for the reviewer, for example what a crop removed. Cleared by the next change.
    public internal(set) var message: String?
    /// Image sizes when the session opened; crops are relative to these.
    public internal(set) var originalSizes: [String: PixelRect]
    /// Movie durations (ms) of each video's base when the session opened; trims are relative to these.
    public internal(set) var originalDurations: [String: Int]
    /// The playhead: how far into the current video (as trimmed) the canvas shows, in ms. Always 0
    /// for images. Annotations with a time range show only while it is inside their range.
    public internal(set) var currentTimeMs = 0
    /// Smallest box or arrow a drag creates, in media pixels. The view sets it from its zoom.
    public var minimumSide: Double = 6
    /// How far from a stroke or handle a click still hits, in media pixels.
    public var hitTolerance: Double = 6

    var undoStack: [Snapshot] = []
    var redoStack: [Snapshot] = []
    var coalesceKey: CoalesceKey?
    var gestureBase: Snapshot?
    var savedDocument: EditorDocument

    /// `originals` gives, for images cropped in an earlier session, the size of the untouched
    /// original and the crop (relative to it) that made the current file. The editor then edits
    /// relative to the original: the crop starts applied, and Reset Crop restores the original.
    ///
    /// `trims` does the same for movies trimmed in an earlier session.
    public init(
        bundle: ReviewBundle, mediaId: String? = nil, originals: [String: PriorCrop] = [:], trims: [String: PriorTrim] = [:]
    ) {
        var document = EditorDocument(bundle: bundle)
        var sizes = Dictionary(bundle.media.map { ($0.id, Self.size(of: $0)) }) { first, _ in first }
        for (id, prior) in originals where sizes[id] != nil {
            sizes[id] = prior.originalSize
            if prior.crop != prior.originalSize { document.crops[id] = prior.crop }
        }
        var durations = Dictionary(bundle.media.compactMap { item in item.durationMs.map { (item.id, $0) } }) { first, _ in first }
        for (id, prior) in trims where durations[id] != nil {
            durations[id] = prior.originalDurationMs
            if prior.trim != TimeRange(startMs: 0, endMs: prior.originalDurationMs) { document.trims[id] = prior.trim }
        }
        self.document = document
        savedDocument = document
        currentMediaId = mediaId.flatMap { id in bundle.media.contains { $0.id == id } ? id : nil } ?? bundle.media.first?.id
        originalSizes = sizes
        originalDurations = durations
    }

    static func size(of item: MediaItem) -> PixelRect {
        PixelRect(x: 0, y: 0, width: item.pixelWidth, height: item.pixelHeight)
    }

    // MARK: Reading

    public var bundle: ReviewBundle { document.bundle }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    /// True when the document differs from the last `markSaved()`.
    public var isDirty: Bool { document != savedDocument }

    public var currentMedia: MediaItem? { currentMediaId.flatMap(media) }
    public var currentFrame: MediaFrame? { currentMedia.map(MediaFrame.init) }

    public func media(_ id: String) -> MediaItem? { bundle.media.first { $0.id == id } }

    public func annotation(_ id: String) -> Annotation? { bundle.annotations.first { $0.id == id } }

    public var selectedAnnotation: Annotation? { selection.flatMap(annotation) }

    /// The 1-based number the reviewer and the intake ticket use: its position in the review.
    public func number(of id: String) -> Int? {
        bundle.annotations.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// Annotations on one media item, in review order.
    public func annotations(on mediaId: String) -> [Annotation] {
        bundle.annotations.filter { $0.mediaId == mediaId }
    }

    // MARK: Navigation (not undoable)

    public mutating func show(mediaId: String) {
        guard media(mediaId) != nil, mediaId != currentMediaId else { return }
        cancelGesture()
        currentMediaId = mediaId
        selection = nil
        currentTimeMs = 0
    }

    /// Selects an annotation (showing its media) or clears the selection.
    public mutating func select(_ id: String?) {
        cancelGesture()
        guard let id, let target = annotation(id) else {
            selection = nil
            return
        }
        if target.mediaId != currentMediaId { currentTimeMs = 0 }
        currentMediaId = target.mediaId
        selection = id
        coalesceKey = nil
        // Show the annotation: move the playhead into its range when it is outside.
        if let range = target.timeRange, !range.contains(currentTimeMs) { currentTimeMs = range.startMs }
    }

    /// Tab / Shift-Tab: the next or previous annotation on the current media, wrapping.
    public mutating func selectNext(forward: Bool = true) {
        guard let mediaId = currentMediaId else { return }
        let ids = annotations(on: mediaId).map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) }
        let next = index.map { ($0 + (forward ? 1 : ids.count - 1)) % ids.count } ?? (forward ? 0 : ids.count - 1)
        select(ids[next])
    }

    public mutating func setTool(_ tool: EditorTool) {
        cancelGesture()
        self.tool = tool
    }

    // MARK: Editing

    /// Edits an annotation's Markdown note. Typing into the same note is one undo step.
    @discardableResult
    public mutating func setNote(_ note: String, for id: String) -> Bool {
        perform(coalescing: .note(id)) { snapshot in
            snapshot.document.bundle.update(id) { $0.note = note }
        }
    }

    /// Toggles an intent over the annotation's *effective* intents (see `IntentToggle`).
    @discardableResult
    public mutating func toggleIntent(_ intent: Intent, for id: String) -> Bool {
        perform { snapshot in
            snapshot.document.bundle.update(id) { $0.intents = IntentToggle.toggled($0.intents, intent, shape: $0.shape) }
        }
    }

    /// Opens or closes a freehand outline.
    @discardableResult
    public mutating func setClosed(_ closed: Bool, for id: String) -> Bool {
        perform { snapshot in
            snapshot.document.bundle.update(id) { annotation in
                if case let .freehand(points, _) = annotation.shape { annotation.shape = .freehand(points: points, closed: closed) }
            }
        }
    }

    @discardableResult
    public mutating func deleteSelection() -> Bool {
        guard let id = selection else { return false }
        return perform { snapshot in
            snapshot.document.bundle.annotations.removeAll { $0.id == id }
            snapshot.selection = nil
            return true
        }
    }

    /// Copies the selected annotation, offset by 2 % of the media, and selects the copy.
    @discardableResult
    public mutating func duplicateSelection() -> Bool {
        guard let original = selectedAnnotation else { return false }
        let copyID = nextAnnotationID()
        return perform { snapshot in
            var copy = original
            copy.id = copyID
            copy.shape = original.shape.translated(dx: 200, dy: 200)
            snapshot.document.bundle.annotations.append(copy)
            snapshot.selection = copyID
            return true
        }
    }

    /// Arrow keys: moves the selection by whole media pixels. Repeated nudges are one undo step.
    @discardableResult
    public mutating func nudgeSelection(dx: Double, dy: Double) -> Bool {
        guard let original = selectedAnnotation, let item = media(original.mediaId) else { return false }
        let scale = Double(NormalizedSpace.max)
        let ndx = Int((dx / Double(max(item.pixelWidth, 1)) * scale).rounded())
        let ndy = Int((dy / Double(max(item.pixelHeight, 1)) * scale).rounded())
        return perform(coalescing: .nudge(original.id)) { snapshot in
            snapshot.document.bundle.update(original.id) { $0.shape = $0.shape.translated(dx: ndx, dy: ndy) }
        }
    }

    // MARK: Undo

    public mutating func undo() {
        cancelGesture()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
    }

    public mutating func redo() {
        cancelGesture()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    /// Records the current document as saved, so `isDirty` is false until the next change.
    public mutating func markSaved() {
        savedDocument = document
    }

    /// Adds media captured while the editor is open (by `filename`, keeping the editor's own
    /// order). Undo history and the saved state learn about them too, so undo never drops a
    /// capture. Returns the ids that were added.
    @discardableResult
    public mutating func mergeMedia(from disk: ReviewBundle) -> [String] {
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

    // MARK: Internals

    var snapshot: Snapshot { Snapshot(document: document, selection: selection, mediaId: currentMediaId, timeMs: currentTimeMs) }

    mutating func restore(_ snapshot: Snapshot) {
        document = snapshot.document
        selection = snapshot.selection.flatMap { annotation($0) == nil ? nil : $0 }
        if let mediaId = snapshot.mediaId, media(mediaId) != nil {
            currentMediaId = mediaId
            currentTimeMs = snapshot.timeMs
        }
        clampTime()
        coalesceKey = nil
        message = nil
    }

    /// Applies one undoable change. `change` returns false (or leaves the document unchanged) to
    /// abort without touching history.
    @discardableResult
    mutating func perform(coalescing key: CoalesceKey? = nil, _ change: (inout Snapshot) -> Bool) -> Bool {
        let before = snapshot
        var after = before
        guard change(&after), after.document != before.document else { return false }
        if key == nil || key != coalesceKey {
            pushUndo(before)
        }
        redoStack.removeAll()
        document = after.document
        selection = after.selection
        currentMediaId = after.mediaId
        currentTimeMs = after.timeMs
        clampTime()
        coalesceKey = key
        message = nil
        return true
    }

    mutating func pushUndo(_ snapshot: Snapshot) {
        undoStack.append(snapshot)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
    }

    /// `aN`, one past the highest numeric id in the document or its history, so an id is never
    /// reused for a different annotation (undo could otherwise bring back two with the same id).
    func nextAnnotationID() -> String {
        let history = undoStack + redoStack
        let all = bundle.annotations + history.flatMap(\.document.bundle.annotations)
        let used = all.compactMap { $0.id.hasPrefix("a") ? Int($0.id.dropFirst()) : nil }
        var number = max(used.max() ?? 0, bundle.annotations.count) + 1
        while annotation("a\(number)") != nil {
            number += 1
        }
        return "a\(number)"
    }
}

/// Intent toggling. The editor shows an annotation's *effective* intents (an empty list means
/// the shape's default), so toggling works on that set:
/// - toggling adds or removes the intent from the effective set;
/// - a result equal to just the default intent, or an empty result, is stored as `[]`;
/// - otherwise intents are stored in canonical `Intent.allCases` order.
public enum IntentToggle {
    public static func toggled(_ intents: [Intent], _ intent: Intent, shape: Shape) -> [Intent] {
        var effective = Set(intents.isEmpty ? [shape.defaultIntent] : intents)
        if effective.contains(intent) { effective.remove(intent) } else { effective.insert(intent) }
        if effective.isEmpty || effective == [shape.defaultIntent] { return [] }
        return Intent.allCases.filter(effective.contains)
    }
}

extension ReviewBundle {
    /// Applies `change` to one annotation; false when the id is unknown.
    mutating func update(_ id: String, _ change: (inout Annotation) -> Void) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        change(&annotations[index])
        return true
    }
}

public extension Shape {
    /// The shape's name in the inspector and for VoiceOver.
    var displayName: String {
        switch self {
        case .rect: "Rectangle"
        case let .freehand(_, closed): closed ? "Outline" : "Open path"
        case .arrow: "Arrow"
        case .insertion: "Insertion"
        case .strike: "Strike"
        }
    }
}

public extension AnnotationEditor {
    /// What VoiceOver reads for an annotation on the canvas: number, shape, intents, and note,
    /// for example "Annotation 1: Rectangle, comment, bug. Field label is clipped."
    /// Spec: docs/06-annotation-editor.md §6.4.
    func accessibilityLabel(for id: String) -> String? {
        guard let annotation = bundle.annotations.first(where: { $0.id == id }), let number = number(of: id) else { return nil }
        let intents = annotation.effectiveIntents.map(\.rawValue).joined(separator: ", ")
        let note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = annotation.timeRange.map { ", shows \(TimeFormat.range($0))" } ?? ""
        return "Annotation \(number): \(annotation.shape.displayName), \(intents)\(time)." + (note.isEmpty ? " No note." : " \(note)")
    }
}
