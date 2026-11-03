import UXReviewKit
import XCTest

/// HS2-QNXVDA: Settings › General › Open at login, through the real Settings window. The app's
/// isolated test mode swaps `SMAppService` for `PreferencesLoginItem`, so this never adds a
/// login item to the machine running it.
extension AppUITests {
    func testOpenAtLoginSwitchFollowsTheLoginItemBothWays() throws {
        continueAfterFailure = false
        let fixture = try UIAppFixture()
        addTeardownBlock { await fixture.cleanup() }
        fixture.launch()
        let settings = openSettings(fixture)
        let toggle = settings.switches["settings-open-at-login"]
        let status = settings.staticTexts["settings-open-at-login-status"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(controlValue(toggle), "0")
        XCTAssertEqual(status.value as? String, LoginItemStatus.notRegistered.message)
        capture("settings-open-at-login-off", settings)

        // The added section must not push Global shortcuts off a short screen: the window stops
        // at the visible screen height and the form scrolls to its last row.
        let lastRow = settings.staticTexts["The capture and record shortcuts also cancel a countdown or stop a recording."]
        XCTAssertTrue(scroll(settings, deltaY: -400, until: lastRow), "Global shortcuts' last row never scrolled into view")
        capture("settings-scrolled-to-shortcuts", settings)
        XCTAssertTrue(scroll(settings, deltaY: 400, until: toggle), "Open at login never scrolled back into view")

        // Control → login item and caption.
        toggle.click()
        XCTAssertTrue(fixture.wait { PreferencesLoginItem(store: fixture.defaults).status == .enabled })
        XCTAssertEqual(controlValue(toggle), "1")
        XCTAssertEqual(status.value as? String, LoginItemStatus.enabled.message)
        XCTAssertFalse(settings.buttons["settings-open-login-items"].exists)
        capture("settings-open-at-login-on", settings)

        // Changed outside the app (System Settings › Login Items) → reopened Settings shows it.
        settings.buttons["_XCUI:CloseWindow"].click()
        XCTAssertTrue(fixture.wait(timeout: 5) { !settings.exists })
        try PreferencesLoginItem(store: fixture.defaults).setEnabled(false)
        _ = openSettings(fixture)
        XCTAssertTrue(fixture.wait { self.controlValue(toggle) == "0" })
        XCTAssertEqual(status.value as? String, LoginItemStatus.notRegistered.message)

        // A further edit after the external change, and persistence across relaunch.
        toggle.click()
        XCTAssertTrue(fixture.wait { PreferencesLoginItem(store: fixture.defaults).status == .enabled })
        fixture.app.terminate()
        fixture.launch()
        _ = openSettings(fixture)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(controlValue(toggle), "1")
        toggle.click()
        XCTAssertTrue(fixture.wait { PreferencesLoginItem(store: fixture.defaults).status == .notRegistered })
        XCTAssertEqual(controlValue(toggle), "0")
    }

    func testOpenAtLoginWaitingForApprovalOffersLoginItemsSettings() throws {
        continueAfterFailure = false
        let fixture = try UIAppFixture()
        addTeardownBlock { await fixture.cleanup() }
        fixture.app.launchEnvironment["UXREVIEW_TEST_LOGIN_ITEM_APPROVAL"] = "1"
        fixture.launch()
        let settings = openSettings(fixture)
        let toggle = settings.switches["settings-open-at-login"]
        let status = settings.staticTexts["settings-open-at-login-status"]
        let openLoginItems = settings.buttons["settings-open-login-items"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(openLoginItems.exists)
        toggle.click()
        XCTAssertTrue(openLoginItems.waitForExistence(timeout: 5))
        XCTAssertEqual(controlValue(toggle), "1")
        XCTAssertEqual(status.value as? String, LoginItemStatus.requiresApproval.message)
        XCTAssertEqual(PreferencesLoginItem(store: fixture.defaults).status, .requiresApproval)
        capture("settings-open-at-login-needs-approval", settings)
        openLoginItems.click()
        XCTAssertTrue(fixture.wait { fixture.defaults.data(forKey: PreferencesLoginItem.openedSettingsKey) != nil })
        toggle.click()
        XCTAssertTrue(fixture.wait(timeout: 5) { !openLoginItems.exists })
        XCTAssertEqual(PreferencesLoginItem(store: fixture.defaults).status, .notRegistered)
        XCTAssertEqual(status.value as? String, LoginItemStatus.notRegistered.message)
    }

    /// Scrolls the form under the window's center in steps until `element` is hittable.
    private func scroll(_ window: XCUIElement, deltaY: CGFloat, until element: XCUIElement) -> Bool {
        let center = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        for _ in 0 ..< 12 {
            if element.exists, element.isHittable { return true }
            center.hover()
            center.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        return element.exists && element.isHittable
    }

    private func openSettings(_ fixture: UIAppFixture) -> XCUIElement {
        fixture.openStatusMenu()
        fixture.clickStatusEntry("Settings…")
        let settings = fixture.app.windows["UX Review Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        return settings
    }
}
