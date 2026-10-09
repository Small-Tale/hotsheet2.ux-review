import AppKit
import UXReviewKit

/// Capture links (`HS2-CWTNY2`, `uxreview://capture?…`, docs/04-capture.md §4.13).
extension CaptureCoordinator {
    /// Opens a `uxreview:` link: an invalid one says why; while a capture is under way it is
    /// ignored (with a note on screen); otherwise its review is prepared and its capture starts.
    func openLink(_ url: URL) {
        let link: CaptureLink
        do {
            link = try CaptureLink.parse(url)
        } catch {
            reportLink(String(describing: error))
            return
        }
        guard phase.isIdle else {
            hud.flash("A capture is already under way", subtitle: "Finish it, then open the link again.")
            return
        }
        do {
            if let draft = try link.prepare(in: store) {
                NotificationCenter.default.post(name: .reviewDraftChanged, object: draft.directory)
            }
        } catch {
            reportLink("Couldn't start its review: \(ReviewSubmitter.describe(error))")
            return
        }
        if let narrate = link.narrate { narrationChoice = narrate }
        // Opening the link brought UX Review forward; step back so the page that opened it is
        // in front again for the capture and becomes the capture's app (the picker never needs
        // UX Review active).
        NSApp.deactivate()
        start(link.request)
    }

    private func reportLink(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't open that UX Review link"
        alert.informativeText = message
        alert.runModal()
    }
}
