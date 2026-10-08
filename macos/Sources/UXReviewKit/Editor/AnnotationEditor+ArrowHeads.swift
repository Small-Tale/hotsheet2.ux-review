import Foundation

/// An arrow's heads (`HS2-HQV9R8`). Spec: docs/06-annotation-editor.md §6.5.
public extension AnnotationEditor {
    /// Sets an arrow's start and end heads; one undo step. Other shapes are left alone.
    @discardableResult
    mutating func setArrowHeads(_ heads: ArrowHeads, for id: String) -> Bool {
        guard case let .arrow(_, current)? = annotation(id)?.shape, current != heads else { return false }
        return perform { snapshot in
            snapshot.document.bundle.update(id) { annotation in
                if case let .arrow(points, _) = annotation.shape { annotation.shape = .arrow(points: points, heads: heads) }
            }
        }
    }
}
