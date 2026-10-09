import AppKit
import UXReviewKit

/// Discarding a review from the Submit Review window: a
/// confirmation, then the draft's editor and session windows close (saving into the draft),
/// and the folder moves to the Trash. When the Trash refuses, a second, destructive
/// confirmation offers to delete it immediately. Spec: docs/07-review-session.md §7.9.
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
        } else if let slug = draft.pendingTicket, draft.pendingToExisting {
            lines.append("Some of its media was already attached to \(slug) in Hot Sheet. Discarding doesn't remove it.")
        } else if let slug = draft.pendingTicket {
            lines.append("\(slug) was already created in Hot Sheet for this review. Discarding doesn't delete that ticket.")
        }
        if draft.isCurrent { lines.append("The next capture starts a new review.") }
        return ("Discard “\(draft.title)”?", lines.joined(separator: "\n\n"))
    }

    /// The second confirmation's text, after the Trash refused `draft`: why (the system's
    /// `reason`, the title already says the Trash refused), and that deleting can't be undone.
    static func deleteMessage(for draft: DraftSummary, reason: String) -> (title: String, detail: String) {
        var lines = [reason]
        if draft.isReadable {
            let captures = "\(draft.captureCount) capture\(draft.captureCount == 1 ? "" : "s")"
            let annotations = "\(draft.annotationCount) annotation\(draft.annotationCount == 1 ? "" : "s")"
            lines.append("Delete it immediately instead? Its \(captures) and \(annotations) are deleted for good. This can't be undone.")
        } else {
            lines.append("Delete the draft folder \(draft.name) immediately instead? This can't be undone.")
        }
        if let slug = draft.pendingTicket {
            lines.append("\(slug) in Hot Sheet is not changed.")
        }
        return ("Couldn't move “\(draft.title)” to the Trash", lines.joined(separator: "\n\n"))
    }

    /// Asks first (as a sheet on `window` when given), then discards. `completion` gets true
    /// once the draft is in the Trash (or, after a second confirmation, deleted).
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
        // Read before moving: the second confirmation describes what would be deleted.
        let summary = try? store.summary(of: directory)
        do {
            try store.discard(directory)
        } catch let error as ReviewDraftError where error.canDeleteInstead {
            guard let summary, confirmDeletion(summary, reason: error.trashRefusal ?? error.description) else { return false }
            do {
                try store.discard(directory, deleteImmediately: true)
            } catch {
                report(error, window: nil)
                return false
            }
        } catch {
            report(error, window: nil)
            return false
        }
        NotificationCenter.default.post(name: .reviewDraftChanged, object: directory)
        return true
    }

    /// The second confirmation, after the Trash refused: **Delete Immediately** is destructive
    /// and has no key equivalent; **Keep Draft** is the default (Return). True to delete.
    private static func confirmDeletion(_ draft: DraftSummary, reason: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return deleteAlert(for: draft, reason: reason).runModal() == .alertFirstButtonReturn
    }

    /// The second confirmation's alert (also rendered by `--render-ui-previews`).
    static func deleteAlert(for draft: DraftSummary, reason: String) -> NSAlert {
        let (title, detail) = deleteMessage(for: draft, reason: reason)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = detail
        let deleteButton = alert.addButton(withTitle: "Delete Immediately")
        deleteButton.hasDestructiveAction = true
        deleteButton.keyEquivalent = ""
        alert.addButton(withTitle: "Keep Draft").keyEquivalent = "\r"
        return alert
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
