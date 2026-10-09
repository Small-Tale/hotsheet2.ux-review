import Foundation

/// How a filed review is confirmed (`HS2-ZYV3SC`, docs/07 §7.2): a transient HUD that fades by
/// itself, or, when something needs the reviewer, the Submit Review window's result page.
public extension SubmittedReview {
    /// True when the result page stays: an earlier failed try left a ticket behind (the page
    /// offers to move it to Hot Sheet's Trash), or the draft folder couldn't be deleted.
    var needsResultWindow: Bool { abandonedTicket != nil || !draftRemoved }

    /// The HUD's headline: "Filed as HS-…" or "Added to HS-…".
    var confirmationTitle: String {
        addedToExistingTicket ? "Added to \(ticket.slug)" : "Filed as \(ticket.slug)"
    }

    /// The HUD's second line: the ticket's title in quotes, then, when only part of the review
    /// went to an existing ticket, what stays in the review.
    var confirmationDetail: String {
        var lines = ["“\(addedToExistingTicket ? ticketTitle ?? title : title)”"]
        if let left = remainingCaptures {
            lines.append("\(left) capture\(left == 1 ? "" : "s") stay\(left == 1 ? "s" : "") in the review for later.")
        }
        return lines.joined(separator: "\n")
    }

    /// How long the HUD shows before fading, in seconds: longer when it has more to say.
    var confirmationSeconds: Double { remainingCaptures == nil ? 5 : 8 }
}
