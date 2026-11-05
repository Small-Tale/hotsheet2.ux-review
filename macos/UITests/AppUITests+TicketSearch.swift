import UXReviewKit
import XCTest

extension AppUITests {
    /// HS2-F2VKVZ: text that isn't an exact reference lists candidates from the real store.
    func testExistingTicketSearchSuggestsCandidates() throws {
        continueAfterFailure = false
        let fixture = try UIAppFixture()
        addTeardownBlock { await fixture.cleanup() }
        let store = fixture.store.path
        let titled = try XCTUnwrap(TicketReference.parse(fixture.run(fixture.cli, [
            "-C", store, "new", "--title", "Account settings page redesign",
        ])))
        let detailed = try XCTUnwrap(TicketReference.parse(fixture.run(fixture.cli, [
            "-C", store, "new", "--title", "Sidebar selection", "--details", "Loses the account settings row",
        ])))
        _ = try fixture.run(fixture.cli, ["-C", store, "new", "--title", "Unrelated"])
        fixture.launch()
        _ = fixture.importImage()
        let session = fixture.openSubmit()
        session.radioGroups["session-destination"].radioButtons["Add to existing ticket"].click()
        let ticket = session.textFields["session-ticket"]
        let submit = session.buttons["session-submit"]
        func match(_ slug: String) -> XCUIElement { session.buttons["ticket-match-\(slug)"] }

        // Title and details text, newest first.
        replace(ticket, with: "account settings")
        XCTAssertTrue(match(detailed).waitForExistence(timeout: 10))
        XCTAssertTrue(match(titled).exists)
        XCTAssertLessThan(match(detailed).frame.minY, match(titled).frame.minY)
        XCTAssertEqual(session.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ticket-match-")).count, 2)
        XCTAssertTrue(session.staticTexts["Choose a ticket matching “account settings”, or enter a slug such as HS-ABC123."].exists)
        XCTAssertFalse(submit.isEnabled)
        capture("ticket-search-wide", session)
        let wide = session.frame.size
        resize(session, to: CGSize(width: 520, height: 680))
        XCTAssertTrue(match(titled).isHittable)
        capture("ticket-search-narrow", session)
        resize(session, to: wide)

        // A slug fragment, then a slug with the wrong prefix (looked up, not found, then searched).
        let suffix = try XCTUnwrap(titled.split(separator: "-").last)
        replace(ticket, with: String(suffix.prefix(4)).lowercased())
        XCTAssertTrue(fixture.wait { match(titled).exists && !match(detailed).exists })
        replace(ticket, with: "ZZ-\(suffix)")
        XCTAssertTrue(session.staticTexts["No ticket ZZ-\(suffix) in project.hs2."].waitForExistence(timeout: 10))
        XCTAssertTrue(match(titled).waitForExistence(timeout: 10))
        replace(ticket, with: "zebra stripes")
        XCTAssertTrue(session.staticTexts["No tickets match “zebra stripes”."].waitForExistence(timeout: 10))
        XCTAssertFalse(match(titled).exists)

        // Choosing a candidate fills the field and runs the ordinary lookup.
        replace(ticket, with: "account settings")
        XCTAssertTrue(match(titled).waitForExistence(timeout: 10))
        match(titled).click()
        XCTAssertEqual(ticket.value as? String, titled)
        XCTAssertTrue(fixture.wait { submit.isEnabled })
        XCTAssertFalse(match(titled).exists)
        capture("ticket-search-chosen", session)
        submit.click()
        XCTAssertTrue(fixture.wait(timeout: 20) { !session.exists })
        XCTAssertEqual(try fixture.tickets().count, 3, "Adding a review must not create another ticket")
        XCTAssertTrue(try fixture.run(fixture.cli, ["-C", store, "show", titled]).contains("UX review: UX review"))
    }
}
