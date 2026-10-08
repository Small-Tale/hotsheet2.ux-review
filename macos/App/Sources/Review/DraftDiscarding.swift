import AppKit
import UXReviewKit

/// Discarding a draft review from the Draft Reviews window or the session window: a
/// confirmation, then the draft's editor and session windows close (saving into the draft),
/// and the folder moves to the Trash. Spec: docs/07-review-session.md §7.9.
@MainActor
enum DraftDiscarding {
    /// The confirmation's text: what goes to the Trash, and what discarding doesn't undo.
    static func message(for draft: DraftSummary) -> (title: String, detail: String) {
        var lines: [String] = []
        if draft.isReadable {
            let captures = "\(draft.captureCount) capture\(draft.captureCount == 1 ? "" : "s")"
            let annotations = "\(draft.annotationCount) annotation\(draft.annotationCount == 1 ? "" : "s")"
            lines.append("Its \(captures) and \(annotations) move to the Trash with the draft folder.")
        } else {
            lines.append("The draft folder \(draft.name) moves to the Trash.")
        }
        if let slug = draft.pendingTicket, draft.pendingNoteOnly {
            lines.append("Its media was already attached to \(slug) in Hot Sheet. Discarding doesn't remove it.")
        } else if let slug = draft.pendingTicket {
            lines.append("\(slug) was already created in Hot Sheet for this review. Discarding doesn't delete that ticket.")
        }
        if draft.isCurrent { lines.append("The next capture starts a new review.") }
        return ("Discard “\(draft.title)”?", lines.joined(separator: "\n\n"))
    }

    /// Asks first (as a sheet on `window` when given), then discards. `completion` gets true
    /// once the draft is in the Trash.
    static func confirm(
        _ directory: URL,
        store: ReviewDraftStore,
        window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        let draft: DraftSummary
        do {
            draft = try store.summary(of: directory)
        } catch {
            report(error, window: window)
            completion(false)
            return
        }
        let (title, detail) = message(for: draft)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        let discardButton = alert.addButton(withTitle: "Move to Trash")
        discardButton.hasDestructiveAction = true
        // Return cancels, so a stray keypress never discards.
        discardButton.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return completion(false) }
            completion(discard(directory, store: store))
        }
        if let window {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { respond(response) } }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            respond(alert.runModal())
        }
    }

    /// Closes the draft's windows (each saves into the draft first), then moves it to the Trash.
    @discardableResult
    static func discard(_ directory: URL, store: ReviewDraftStore) -> Bool {
        EditorWindowController.close(directory: directory)
        ReviewSessionWindowController.close(directory: directory)
        do {
            try store.discard(directory)
            NotificationCenter.default.post(name: .reviewDraftChanged, object: directory)
            return true
        } catch {
            report(error, window: nil)
            return false
        }
    }

    private static func report(_ error: Error, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't discard the review"
        alert.informativeText = "\((error as? ReviewDraftError)?.description ?? ReviewSubmitter.describe(error)) The draft is kept."
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
