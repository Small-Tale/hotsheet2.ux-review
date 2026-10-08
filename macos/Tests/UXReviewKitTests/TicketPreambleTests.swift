import Foundation
import Testing
@testable import UXReviewKit

/// The editable preamble of a filed review (docs/07 §7.2.3): templates, placeholders, the
/// per-draft `ticket-text.json`, and that filing uses the edited text for the right mode only.
struct TicketPreambleTests {
    @Test func standardTemplatesFillInToTheFiledText() throws {
        let bundle = try TestSupport.exampleBundle()
        let instructions = TicketPreamble.text(.newTicket, for: bundle)
        #expect(instructions.hasPrefix("## Instructions for the AI processing this ticket\n\nThis is a **UX review intake ticket**"))
        #expect(instructions.contains("1. Read every annotation below. `attachment:review.json` is the canonical"))
        #expect(instructions.contains("(schema `\(bundle.schema)`, see"))
        #expect(instructions.contains("Reference the same captured media by name (`attachment:capture-1.png`, `attachment:capture-2.mov`)"))
        #expect(instructions.hasSuffix("5. Add a note here listing every ticket you created, then complete this ticket."))
        #expect(!instructions.contains("{{"))
        #expect(TicketComposer.compose(bundle).ticket.details.hasPrefix(instructions + "\n\n## Reviewer summary"))

        let intro = TicketPreamble.text(.existingTicket, for: bundle, storedNames: ["review.json": "review-2.json"])
        #expect(
            intro
                .hasPrefix(
                    "## UX review: Settings window polish\n\nFeedback on this ticket, added with UX Review: 2 captures and 6 annotations."
                )
        )
        #expect(intro.contains("The captures and `attachment:review-2.json` are attached"))
        #expect(!intro.contains("{{"))
    }

    @Test func renderFillsKnownNamesOnceAndLeavesTheRestAsTyped() {
        let values = ["title": "A {{counts}} title", "counts": "2"]
        #expect(TicketPreamble.render("{{title}} / {{ counts }}", values: values) == "A {{counts}} title / 2")
        #expect(TicketPreamble.render("{{unknown}} {{title", values: values) == "{{unknown}} {{title")
        #expect(TicketPreamble.render("", values: values) == "")
        #expect(TicketPreamble.render("}} {{}} {", values: values) == "}} {{}} {")
    }

    @Test func eachModeListsTheVariablesItsStandardTextUses() {
        #expect(TicketPreamble.variables(for: .newTicket).map(\.name) == ["record", "schema", "media"])
        #expect(TicketPreamble.variables(for: .existingTicket).map(\.name) == ["title", "counts", "record", "schema"])
    }

    @Test func anEditedOrClearedPreambleReplacesOnlyThePreamble() throws {
        let bundle = try TestSupport.exampleBundle()
        let edited = TicketComposer.compose(bundle, preamble: "## Please\n\nFix {{title}} ({{media}}).").ticket.details
        let media = "`attachment:capture-1.png`, `attachment:capture-2.mov`"
        #expect(edited.hasPrefix("## Please\n\nFix Settings window polish (\(media)).\n\n## Reviewer summary"))
        #expect(edited.contains("### #1 · change"))

        let cleared = TicketComposer.compose(bundle, preamble: "  \n").ticket.details
        #expect(cleared.hasPrefix("## Reviewer summary"))

        let note = TicketComposer.note(for: bundle, preamble: "Notes for {{title}}")
        #expect(note.hasPrefix("Notes for Settings window polish\n\n### Reviewer summary"))
        #expect(TicketComposer.note(for: bundle, preamble: "").hasPrefix("### Reviewer summary"))
    }

    @Test func draftTicketTextStoresOnlyEditsAndGoesBackToStandard() throws {
        let directory = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(DraftTicketText.filename)

        #expect(DraftTicketText.load(from: directory) == DraftTicketText())
        var text = DraftTicketText()
        text[.newTicket] = "Mine"
        try text.save(to: directory)
        #expect(DraftTicketText.load(from: directory) == DraftTicketText(newTicket: "Mine"))
        #expect(DraftTicketText.load(from: directory).template(.existingTicket) == TicketPreamble.standard(.existingTicket))

        // The standard text itself is stored as "standard", so it follows later wording changes.
        text[.newTicket] = TicketPreamble.standard(.newTicket)
        #expect(text.isStandard)
        try text.save(to: directory)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // A cleared preamble is an edit (no preamble at all), not the standard one.
        text[.existingTicket] = ""
        try text.save(to: directory)
        #expect(DraftTicketText.load(from: directory) == DraftTicketText(existingTicket: ""))

        try Data("not json".utf8).write(to: file)
        #expect(DraftTicketText.load(from: directory) == DraftTicketText())
    }

    @Test func editsInterleaveAcrossModesAndResets() throws {
        let fixture = try DraftSubmitterTests.Fixture()
        let directory = try fixture.draft(captures: 1).directory
        let store = fixture.store
        try store.setTicketText("A", for: .newTicket, in: directory)
        try store.setTicketText("B", for: .existingTicket, in: directory)
        try store.setTicketText("A2", for: .newTicket, in: directory)
        #expect(DraftTicketText.load(from: directory) == DraftTicketText(newTicket: "A2", existingTicket: "B"))
        try store.setTicketText(nil, for: .existingTicket, in: directory)
        #expect(DraftTicketText.load(from: directory) == DraftTicketText(newTicket: "A2"))
        try store.setTicketText(nil, for: .newTicket, in: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(DraftTicketText.filename).path))
        try store.setTicketText("again", for: .newTicket, in: directory)
        #expect(DraftTicketText.load(from: directory).newTicket == "again")
    }

    @Test func filingANewTicketUsesTheDraftsNewTicketPreamble() throws {
        let fixture = try DraftSubmitterTests.Fixture()
        let directory = try fixture.draft(captures: 1).directory
        try fixture.store.setTicketText("Intake for {{title}}", for: .newTicket, in: directory)
        try fixture.store.setTicketText("Not this one", for: .existingTicket, in: directory)
        _ = try fixture.submitter().submit(directory, title: "Checkout")
        let details = try #require(fixture.client.created.first).details
        #expect(details.hasPrefix("Intake for Checkout\n\n## Capture context"))
        #expect(!details.contains("Not this one"))
    }

    @Test func addingToAnExistingTicketUsesTheDraftsExistingTicketPreamble() throws {
        let fixture = try DraftSubmitterTests.Fixture()
        let directory = try fixture.draft(captures: 1).directory
        try fixture.store.setTicketText("Not this one", for: .newTicket, in: directory)
        try fixture.store.setTicketText("More on {{title}}: {{counts}}", for: .existingTicket, in: directory)
        _ = try fixture.submitter().submit(directory, title: "Checkout", into: ExistingTicketSubmitterTests.existing)
        let note = try #require(fixture.client.notes.first).markdown
        #expect(note.hasPrefix("More on Checkout: 1 capture and 1 annotation\n\n### Capture context"))
        #expect(!note.contains("Not this one"))
    }
}

/// The Submit Review window shows the preamble rendered from these blocks (§7.2.3).
struct MarkdownBlockTests {
    @Test func parsesHeadingsListsAndParagraphs() {
        let blocks = MarkdownBlock.parse("""
        ## Instructions

        First line
        joined line.

        1. One `code`
           continued
        12) Twelve
        - Bullet
        #NotAHeading
        ####### seven
        """)
        #expect(blocks == [
            .heading(level: 2, text: "Instructions"),
            .paragraph("First line joined line."),
            .listItem(marker: "1.", text: "One `code` continued"),
            .listItem(marker: "12.", text: "Twelve"),
            .listItem(marker: "•", text: "Bullet"),
            .paragraph("#NotAHeading ####### seven"),
        ])
        #expect(MarkdownBlock.parse("") == [])
        #expect(MarkdownBlock.parse("\n  \n") == [])
    }

    @Test func theStandardPreamblesParseIntoTheirParts() throws {
        let bundle = try TestSupport.exampleBundle()
        let blocks = MarkdownBlock.parse(TicketPreamble.text(.newTicket, for: bundle))
        #expect(blocks.first == .heading(level: 2, text: "Instructions for the AI processing this ticket"))
        #expect(blocks.filter { if case .listItem = $0 { true } else { false } }.count == 5)
        #expect(MarkdownBlock.parse(TicketPreamble.text(.existingTicket, for: bundle)).count == 2)
    }
}
