import AppKit
import UXReviewKit

/// Open in Hot Sheet after filing (HS2-ZEF6XD, docs/07 §7.2).
extension ReviewSessionModel {
    /// Looks for the running Hot Sheet web client, so the result can offer Open in Hot Sheet.
    func findHotSheetLink(for review: SubmittedReview) {
        let find = hotSheetLinkFinder
        let store = review.storePath, slug = review.ticket.slug
        Task { [weak self] in
            let link = await Task.detached { find(store, slug) }.value
            guard let self, case let .submitted(current) = session.phase, current.ticket.slug == slug else { return }
            hotSheetLink = link
        }
    }

    func openInHotSheet() {
        guard let link = hotSheetLink else { return }
        NSWorkspace.shared.open(link)
    }
}
