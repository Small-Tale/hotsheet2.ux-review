import CoreGraphics
import UXReviewKit

/// Arrow heads in the editor previews (`HS2-HQV9R8`, docs/06 §6.5).
extension EditorPreviews {
    /// One arrow per head style (start and end alike) in a column on the right, then a span with
    /// flat ends selected, so the inspector shows its Arrow heads menus.
    static let arrowHeadStyles: [EditorScript.Step] = ArrowHead.allCases.enumerated().flatMap { index, head in
        let y = 140 + Double(index) * 64
        return [
            .tool(.arrow), .drag([CGPoint(x: 1380, y: y), CGPoint(x: 1560, y: y + 24)]),
            .heads(start: head, end: head), .note("\(head.displayName) at both ends"),
        ] as [EditorScript.Step]
    } + [
        .tool(.arrow), .drag([CGPoint(x: 880, y: 250), CGPoint(x: 880, y: 330)]),
        .heads(start: .flat, end: .flat), .note("Match this gap to the one above."),
    ]

    /// A note, an intent toggle, or an arrow's heads, on the selected annotation.
    static func editSelection(_ step: EditorScript.Step, in editor: inout AnnotationEditor) {
        guard let id = editor.selection else { return }
        switch step {
        case let .note(text): editor.setNote(text, for: id)
        case let .intent(intent): editor.toggleIntent(intent, for: id)
        case let .heads(start, end):
            if case let .arrow(_, current)? = editor.annotation(id)?.shape {
                editor.setArrowHeads(ArrowHeads(start: start ?? current.start, end: end ?? current.end), for: id)
            }
        default: break
        }
    }
}
