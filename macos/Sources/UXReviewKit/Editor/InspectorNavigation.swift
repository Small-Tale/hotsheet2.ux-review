import Foundation

/// The inspector's navigation stack (`HS2-4R84WH`, docs/06 §6.5.1): the annotation list at the
/// root, and the selected annotation's editor pushed on top. The editor's selection is the single
/// source of truth, so the stack can never disagree with the canvas:
///
/// - selecting an annotation (a list row, the canvas, Tab, an undo) shows its editor;
/// - selecting another one while an editor shows replaces it (the stack never grows past one);
/// - Back (or ⌘[) pops to the list and deselects; deselecting on the canvas (Esc, a click on
///   nothing, deleting the annotation, showing another capture) pops too.
public enum InspectorNavigation {
    /// The pushed pages for `selection`: none (just the list) or the selected annotation's editor.
    public static func path(selection: String?) -> [String] {
        selection.map { [$0] } ?? []
    }

    /// What the stack's change to `path` asks of the editor while `current` is selected: `nil` when
    /// nothing changes, `.some(nil)` to deselect (Back), `.some(id)` to select `id`.
    public static func selection(afterNavigatingTo path: [String], current: String?) -> String?? {
        let target = path.last
        return target == current ? nil : .some(target)
    }
}
