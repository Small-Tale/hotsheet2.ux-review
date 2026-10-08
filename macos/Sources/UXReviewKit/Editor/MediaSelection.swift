import Foundation

/// Which captures are selected in the editor's media strip (`HS2-0TQ6RP`). A plain click selects
/// one capture, ⌘-click adds or removes one, and ⇧-click selects the range from the anchor (the
/// last plain- or ⌘-clicked capture) to the clicked one. The **primary** capture is the one the
/// canvas shows: the last one clicked, or after ⌘-clicking it away, its nearest selected neighbor.
///
/// The selection only holds while the editor shows its primary. Whenever something else changes
/// the capture on screen (undo, selecting an annotation, a removal, a script), `selected` is just
/// that capture, so the strip can never disagree with the canvas. Spec: docs/06 §6.7.2.
public struct MediaSelection: Equatable, Sendable {
    /// How a thumbnail was clicked.
    public enum Click: String, CaseIterable, Sendable {
        /// A plain click: just this capture.
        case plain
        /// ⌘-click: add it, or take it out (never the last one).
        case toggle
        /// ⇧-click: the range from the anchor to it.
        case extend
    }

    public private(set) var ids: Set<String> = []
    public private(set) var primary: String?
    public private(set) var anchor: String?

    public init() {}

    /// The selected captures in strip `order`, while the editor shows `current`: empty without a
    /// current capture, just `current` once the editor moved away from the primary.
    public func selected(order: [String], current: String?) -> [String] {
        guard let current, order.contains(current) else { return [] }
        guard primary == current else { return [current] }
        return order.filter { $0 == current || ids.contains($0) }
    }

    /// Applies a click on `id`. Unknown ids change nothing. Afterwards the editor shows `primary`.
    public mutating func click(_ id: String, _ click: Click, order: [String], current: String?) {
        guard order.contains(id) else { return }
        let shown = selected(order: order, current: current)
        // A stale selection (the editor moved away from it) starts over from what is shown.
        let from = primary == current && anchor.map(order.contains) == true ? anchor : current
        switch click {
        case .plain:
            set([id], primary: id, anchor: id)
        case .toggle:
            guard shown.contains(id) else {
                set(shown + [id], primary: id, anchor: id)
                return
            }
            let rest = shown.filter { $0 != id }
            // The last selected capture stays selected: something is always on the canvas.
            guard let fallback = rest.last else { return set(shown, primary: id, anchor: id) }
            var next = current ?? fallback
            if id == current {
                let position = order.firstIndex(of: id) ?? 0
                next = rest.first { (order.firstIndex(of: $0) ?? 0) > position } ?? fallback
            }
            set(rest, primary: next, anchor: from == id || from == nil ? next : from)
        case .extend:
            let start = from ?? id
            guard let lower = order.firstIndex(of: start), let upper = order.firstIndex(of: id) else {
                return set([id], primary: id, anchor: id)
            }
            set(Array(order[min(lower, upper) ... max(lower, upper)]), primary: id, anchor: start)
        }
    }

    /// Forgets captures no longer in the draft, so a later capture that reuses an id is never
    /// selected by accident.
    public mutating func prune(to order: [String]) {
        let present = Set(order)
        ids.formIntersection(present)
        if let primary, !present.contains(primary) { self.primary = nil }
        if let anchor, !present.contains(anchor) { self.anchor = nil }
    }

    /// What removing from the thumbnail `id` acts on (its ✕ or context menu): the whole selection
    /// when `id` is part of it, else just `id`. With no `id` (the Edit menu, ⌘⌫), the selection.
    public func removalTargets(for id: String?, order: [String], current: String?) -> [String] {
        let shown = selected(order: order, current: current)
        guard let id else { return shown }
        guard order.contains(id) else { return [] }
        return shown.contains(id) ? shown : [id]
    }

    private mutating func set(_ ids: [String], primary: String, anchor: String?) {
        self.ids = Set(ids)
        self.primary = primary
        self.anchor = anchor
    }
}

/// The words of the sheet that asks before removing captures in the editor, and of the menu
/// items that remove them (docs/06 §6.7.1, §6.7.2).
public struct CaptureRemovalPrompt: Equatable, Sendable {
    public var message: String
    public var detail: String
    public var button: String

    /// `filenames` of the captures to remove (at least one), with `annotations` on them in all.
    public init(filenames: [String], annotations: Int) {
        let count = filenames.count
        let theirs = count == 1 ? "its" : "their"
        let notes = annotations == 0 ? "" : annotations == 1 ? " and \(theirs) annotation" : " and \(theirs) \(annotations) annotations"
        if count == 1 {
            message = "Remove \(filenames[0]) from this review?"
            detail = "The capture\(notes) will be deleted from the draft. You can't undo this."
        } else {
            message = "Remove \(count) captures from this review?"
            detail = "The captures\(notes) will be deleted from the draft. You can't undo this."
        }
        button = Self.title(count: count)
    }

    /// "Remove Capture" / "Remove 3 Captures".
    public static func title(count: Int) -> String {
        count == 1 ? "Remove Capture" : "Remove \(count) Captures"
    }
}
