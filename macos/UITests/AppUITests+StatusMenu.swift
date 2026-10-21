import XCTest

extension AppUITests {
    func testDismissedStatusMenuReportsStateAndExplicitReopenWorks() throws {
        continueAfterFailure = false
        let fixture = try UIAppFixture()
        addTeardownBlock { await fixture.cleanup() }
        fixture.launch()
        fixture.openStatusMenu()
        fixture.app.typeKey(.escape, modifierFlags: [])
        let menu = fixture.app.statusItems["status-item"].menus.firstMatch
        XCTAssertTrue(fixture.wait { !menu.exists || !menu.isHittable })
        // Predicate expectations poll at roughly one-second intervals.
        let dismissed = fixture.statusEntryReadiness("Open UX Review", timeout: 2)
        let diagnostic = XCTAttachment(string: dismissed.diagnostics)
        diagnostic.name = "status-menu-deliberately-dismissed"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        XCTAssertFalse(dismissed.isReady, dismissed.diagnostics)
        XCTAssertTrue(dismissed.diagnostics.contains("hittable=false"), dismissed.diagnostics)
        XCTAssertTrue(dismissed.diagnostics.contains("stableSamples=0"), dismissed.diagnostics)
        fixture.openStatusMenu()
        XCTAssertTrue(fixture.statusEntryReadiness("Open UX Review").isReady)
        let screenshot = XCTAttachment(screenshot: menu.screenshot())
        screenshot.name = "status-menu-after-explicit-reopen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        fixture.clickStatusEntry("Open UX Review")
        XCTAssertTrue(fixture.app.groups["annotation-canvas"].waitForExistence(timeout: 10))
    }
}
