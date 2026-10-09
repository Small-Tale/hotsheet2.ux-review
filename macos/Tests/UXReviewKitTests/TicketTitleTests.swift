import Foundation
import Testing
@testable import UXReviewKit

/// HS2-CR8M4X: the new ticket's title can be typed in Submit Review. Spec: docs/07 §7.2.1.
struct TicketTitleTests {
    @Test func typedTitlesAreOneTrimmedLineAndTheStandardOneIsNone() {
        let standard = "UX review: Checkout"
        #expect(DraftTicketText.ticketTitle("  Fix the checkout form ", standard: standard) == "Fix the checkout form")
        #expect(DraftTicketText.ticketTitle("Two\nlines\r\nhere", standard: standard) == "Two lines here")
        #expect(DraftTicketText.ticketTitle("   ", standard: standard) == nil)
        #expect(DraftTicketText.ticketTitle(nil, standard: standard) == nil)
        #expect(DraftTicketText.ticketTitle(" UX review: Checkout ", standard: standard) == nil)
        #expect(TicketComposer.standardTitle(reviewTitle: "  Checkout \n") == standard)
    }

    @Test func composingUsesTheTypedTitleElseTheStandardOne() throws {
        let bundle = try TestSupport.exampleBundle()
        #expect(TicketComposer.compose(bundle).ticket.title == "UX review: \(bundle.title)")
        #expect(TicketComposer.compose(bundle, title: "Fix the form").ticket.title == "Fix the form")
        // The body is the same either way: the title is only the ticket's title.
        #expect(TicketComposer.compose(bundle).ticket.details == TicketComposer.compose(bundle, title: "Fix the form").ticket.details)
    }

    @Test func theTitleIsKeptWithTheDraftAndClearsBackToStandard() throws {
        let fixture = try DraftSubmitterTests.Fixture()
        let directory = try fixture.draft(captures: 1).directory
        let store = fixture.store
        let standard = try TicketComposer.standardTitle(store.load(directory).bundle)
        try store.setTicketTitle("Fix the form", in: directory)
        #expect(DraftTicketText.load(from: directory).newTicketTitle == "Fix the form")
        // It sits beside an edited preamble, and each clears on its own.
        try store.setTicketText("Intake", for: .newTicket, in: directory)
        try store.setTicketTitle(" Fix the form again ", in: directory)
        #expect(DraftTicketText.load(from: directory) == DraftTicketText(newTicket: "Intake", newTicketTitle: "Fix the form again"))
        try store.setTicketText(nil, for: .newTicket, in: directory)
        #expect(DraftTicketText.load(from: directory) == DraftTicketText(newTicketTitle: "Fix the form again"))
        // Typing the standard title, or clearing it, goes back to standard and removes the file.
        try store.setTicketTitle(standard, in: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(DraftTicketText.filename).path))
        try store.setTicketTitle("Back", in: directory)
        try store.setTicketTitle("", in: directory)
        #expect(DraftTicketText.load(from: directory) == DraftTicketText())
        // An older ticket-text.json without the field reads as the standard title.
        try Data(#"{"newTicket": "Old"}"#.utf8).write(to: directory.appendingPathComponent(DraftTicketText.filename))
        #expect(DraftTicketText.load(from: directory) == DraftTicketText(newTicket: "Old"))
    }

    @Test func aNewTicketIsFiledUnderTheTypedTitle() throws {
        let fixture = try DraftSubmitterTests.Fixture()
        let directory = try fixture.draft(captures: 1).directory
        try fixture.store.setTicketTitle("Checkout: clipped labels", in: directory)
        _ = try fixture.submitter().submit(directory, title: "Checkout")
        #expect(try #require(fixture.client.created.first).title == "Checkout: clipped labels")
    }

    @Test func withoutATypedTitleTheTicketFollowsTheReviewTitle() throws {
        let fixture = try DraftSubmitterTests.Fixture()
        let directory = try fixture.draft(captures: 1).directory
        _ = try fixture.submitter().submit(directory, title: "Checkout")
        #expect(try #require(fixture.client.created.first).title == "UX review: Checkout")
    }

    @Test func theCommandLineTakesATicketTitleForNewTicketsOnly() throws {
        #expect(try SubmitCommand.parse(["--submit", "--ticket-title", "Fix it"])?.ticketTitle == "Fix it")
        #expect(try SubmitCommand.parse(["--submit"])?.ticketTitle == nil)
        #expect(throws: CommandLineError.invalidValue("--ticket-title", "not with --to-ticket")) {
            try SubmitCommand.parse(["--submit", "--ticket-title", "Fix it", "--to-ticket", "HS-ABCD12"])
        }
        #expect(throws: CommandLineError.invalidValue("--ticket-title", " ")) {
            try SubmitCommand.parse(["--submit", "--ticket-title", " "])
        }
        #expect(throws: CommandLineError.missingValue("--ticket-title")) {
            try SubmitCommand.parse(["--submit", "--ticket-title"])
        }
    }
}
