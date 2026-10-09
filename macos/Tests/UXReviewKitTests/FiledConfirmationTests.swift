import Foundation
import Testing
@testable import UXReviewKit

/// HS2-ZYV3SC: a filed review is confirmed by a transient HUD unless it needs the reviewer.
struct FiledConfirmationTests {
    static func review(
        existing: Bool = false, draftRemoved: Bool = true, remaining: Int? = nil, abandoned: String? = nil
    ) -> SubmittedReview {
        SubmittedReview(
            ticket: CreatedTicket(slug: "HS-ABCD12", file: nil), title: "Checkout", mediaCount: 2, annotationCount: 3,
            storePath: "/p.hs2", submittedAt: Date(timeIntervalSince1970: 0), draftRemoved: draftRemoved,
            addedToExistingTicket: existing, ticketTitle: existing ? "Accounts page" : nil,
            remainingCaptures: remaining, abandonedTicket: abandoned
        )
    }

    @Test func onlyALeftBehindTicketOrAKeptFolderKeepsTheResultWindow() {
        #expect(!Self.review().needsResultWindow)
        #expect(!Self.review(existing: true).needsResultWindow)
        #expect(!Self.review(existing: true, remaining: 1).needsResultWindow)
        #expect(Self.review(existing: true, abandoned: "HS-OLD123").needsResultWindow)
        #expect(Self.review(draftRemoved: false).needsResultWindow)
    }

    @Test func theHUDSaysWhereTheReviewWentAndWhatStays() {
        #expect(Self.review().confirmationTitle == "Filed as HS-ABCD12")
        #expect(Self.review().confirmationDetail == "“Checkout”")
        #expect(Self.review().confirmationSeconds == 5)
        let partial = Self.review(existing: true, remaining: 1)
        #expect(partial.confirmationTitle == "Added to HS-ABCD12")
        #expect(partial.confirmationDetail == "“Accounts page”\n1 capture stays in the review for later.")
        #expect(partial.confirmationSeconds == 8)
        #expect(Self.review(existing: true, remaining: 2).confirmationDetail.hasSuffix("2 captures stay in the review for later."))
    }
}
