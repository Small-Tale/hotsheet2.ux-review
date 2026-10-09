import AppKit
import SwiftUI
import UXReviewKit

/// HS2-ZYV3SC: the transient HUD that confirms a filing, on a light desktop-like backdrop:
/// filed as a new ticket, with Hot Sheet's web client running (Open in Hot Sheet), and part of
/// a review added to an existing ticket.
extension ReviewSessionPreviews {
    static func renderFiledHUD(_ model: ReviewSessionModel, to directory: URL) throws -> [URL] {
        let filed = SubmittedReview(
            ticket: CreatedTicket(slug: "HS-R58EY5"), title: model.session.bundle.title, mediaCount: 3, annotationCount: 4,
            storePath: "/Users/me/Code/acme-mail.hs2", submittedAt: Date()
        )
        var partial = filed
        partial.addedToExistingTicket = true
        partial.ticket = CreatedTicket(slug: "HS-YCDZ2A")
        partial.ticketTitle = "Accounts settings page redesign"
        partial.remainingCaptures = 1
        var written: [URL] = []
        for (name, review, link) in [
            ("filed-hud", filed, nil), ("filed-hud-hotsheet", filed, URL(string: "http://127.0.0.1:4175/?store=/Users/me/Code/acme-mail")),
            ("filed-hud-partial", partial, nil),
        ] {
            model.hotSheetLink = link
            let view = FiledHUDView(review: review, model: model)
                .padding(40)
                .background(Color(white: 0.9))
            written.append(try snapshot(view, size: CGSize(width: 420, height: 220), to: directory.appendingPathComponent("\(name).png")))
        }
        model.hotSheetLink = nil
        return written
    }
}
