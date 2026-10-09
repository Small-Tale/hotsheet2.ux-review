import Foundation

/// `trim-mode` script steps (`HS2-ECE7WY`, docs/06 §6.9, §6.10).
public extension EditorScript {
    /// What a `trim-mode` step does (`HS2-ECE7WY`).
    enum TrimModeAction: Equatable, Sendable {
        case enter
        case set(start: Int?, end: Int?)
        case commit
        case cancel
    }
}

extension EditorScript {
    /// Trim mode steps (`HS2-ECE7WY`): entering needs a video; the others need the mode on.
    static func applyTrimMode(_ action: TrimModeAction, in session: EditorSession) throws {
        if action == .enter {
            guard session.editor.enterTrimMode() else { throw StepFailure.reason("Trim mode needs a video (and isn't on yet)") }
            return
        }
        guard session.editor.trimMode != nil else { throw StepFailure.reason("Trim mode is not on") }
        switch action {
        case let .set(start, end):
            if let start { session.editor.setTrimModeEnd(.trimStart, toMs: start) }
            if let end { session.editor.setTrimModeEnd(.trimEnd, toMs: end) }
        case .commit: session.editor.commitTrimMode()
        case .cancel: session.editor.cancelTrimMode()
        case .enter: break
        }
    }
}
