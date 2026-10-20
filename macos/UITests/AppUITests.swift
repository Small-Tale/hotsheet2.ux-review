import UXReviewKit
import XCTest

@MainActor
final class AppUITests: XCTestCase {
    func testStatusMenuSettingsPersistAcrossRelaunch() throws {
        continueAfterFailure = false
        let fixture = try UIAppFixture()
        addTeardownBlock { await fixture.cleanup() }
        fixture.launch()
        fixture.openStatusMenu()
        capture("status-menu", fixture.app.statusItems["status-item"].menus.firstMatch)
        fixture.clickStatusEntry("Settings…")
        let settings = fixture.app.windows["UX Review Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        capture("settings-initial", settings)
        let toggle = settings.switches["settings-downscale"]
        XCTAssertTrue(toggle.exists)
        XCTAssertEqual(controlValue(toggle), "0")
        toggle.click()
        XCTAssertEqual(controlValue(toggle), "1")
        capture("settings-downscale-on", settings)
        fixture.app.terminate()
        fixture.launch()
        fixture.openStatusMenu()
        fixture.clickStatusEntry("Settings…")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(controlValue(toggle), "1")
        toggle.click()
        XCTAssertEqual(controlValue(toggle), "0")
        XCTAssertTrue(fixture.wait {
            fixture.defaults.synchronize()
            return !CaptureSettingsStore.load(from: fixture.defaults).downscaleForAI
        })
        capture("settings-downscale-off", settings)
    }

    func testImportAnnotateUndoRedoAndFileNewTicket() throws {
        continueAfterFailure = false
        let fixture = try UIAppFixture()
        addTeardownBlock { await fixture.cleanup() }
        fixture.launch()
        let canvas = fixture.importImage()
        let editor = fixture.app.windows.containing(.group, identifier: "annotation-canvas").firstMatch
        fixture.app.checkBoxes["tool-rect"].click()
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3))
        start.click(forDuration: 0.2, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.65)))
        XCTAssertTrue(fixture.wait { canvas.label.contains("1 annotation") })
        canvas.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(fixture.wait { canvas.label.contains("0 annotations") })
        canvas.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(fixture.wait { canvas.label.contains("1 annotation") })
        let note = fixture.app.textViews["annotation-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.click()
        note.typeText("UI regression note")
        capture("editor-annotated-wide", editor)
        resize(editor, to: CGSize(width: 900, height: 620))
        capture("editor-annotated-narrow", editor)
        let session = fixture.openSubmit()
        replace(session.textFields["session-title"], with: "Live UI new review")
        let summary = session.textViews["session-summary"]
        summary.click()
        summary.typeText("Submitted through the running application")
        capture("submit-new-wide", session)
        resize(session, to: CGSize(width: 520, height: 680))
        capture("submit-new-narrow", session)
        captureDetails("submit-new-details", session)
        let submit = session.buttons["session-submit"]
        XCTAssertTrue(submit.isEnabled)
        submit.click()
        XCTAssertTrue(fixture.wait(timeout: 20) { !session.exists })
        captureConfirmation("filed-new", fixture.app)
        XCTAssertEqual(try fixture.tickets().count, 1)
        let bundle = try XCTUnwrap(fixture.attachedBundles().first)
        XCTAssertEqual(bundle.title, "Live UI new review")
        XCTAssertEqual(bundle.summary, "Submitted through the running application")
        XCTAssertEqual(bundle.annotations.count, 1)
        XCTAssertEqual(bundle.annotations.first?.note, "UI regression note")
        try fixture.verifyAttachedImage(bundle)
        XCTAssertNil(try fixture.drafts.current())
    }

    func testExistingTicketLookupModeSwitchAndSubmission() throws {
        continueAfterFailure = false
        let fixture = try UIAppFixture()
        addTeardownBlock { await fixture.cleanup() }
        let created = try fixture.run(fixture.cli, ["-C", fixture.store.path, "new", "--title", "Existing UI destination"])
        let slug = try XCTUnwrap(TicketReference.parse(created))
        fixture.launch()
        _ = fixture.importImage()
        let session = fixture.openSubmit()
        replace(session.textFields["session-title"], with: "Live UI follow-up")
        let destination = session.radioGroups["session-destination"]
        destination.radioButtons["Add to existing ticket"].click()
        let ticket = session.textFields["session-ticket"]
        replace(ticket, with: "HS-NOTFOUND")
        XCTAssertTrue(session.staticTexts["No ticket HS-NOTFOUND in project.hs2."].waitForExistence(timeout: 10))
        XCTAssertFalse(session.buttons["session-submit"].isEnabled)
        replace(ticket, with: slug)
        XCTAssertTrue(fixture.wait { session.buttons["session-submit"].isEnabled })
        destination.radioButtons["New ticket"].click()
        XCTAssertFalse(ticket.exists)
        destination.radioButtons["Add to existing ticket"].click()
        XCTAssertEqual(ticket.value as? String, slug)
        XCTAssertTrue(fixture.wait { session.buttons["session-submit"].isEnabled })
        XCTAssertLessThan(destination.frame.maxY, session.textFields["session-title"].frame.minY)
        capture("submit-existing-wide", session)
        resize(session, to: CGSize(width: 520, height: 680))
        capture("submit-existing-narrow", session)
        captureDetails("submit-existing-details", session)
        session.buttons["session-submit"].click()
        XCTAssertTrue(fixture.wait(timeout: 20) { !session.exists })
        captureConfirmation("filed-existing", fixture.app)
        XCTAssertEqual(try fixture.tickets().count, 1, "Adding a review must not create another ticket")
        let stored = try fixture.run(fixture.cli, ["-C", fixture.store.path, "show", slug])
        XCTAssertTrue(stored.contains("UX review: Live UI follow-up"))
        let bundle = try XCTUnwrap(fixture.attachedBundles().first)
        XCTAssertEqual(bundle.title, "Live UI follow-up")
        try fixture.verifyAttachedImage(bundle)
        XCTAssertNil(try fixture.drafts.current())
    }

    func testRealScreenCaptureFromStatusMenu() throws {
        continueAfterFailure = false
        let required = ProcessInfo.processInfo.environment["UXREVIEW_UI_REAL_CAPTURE"] == "1"
        try XCTSkipUnless(required, "Opt in with UXREVIEW_UI_REAL_CAPTURE=1 on a permitted desktop")
        let fixture = try UIAppFixture()
        addTeardownBlock { await fixture.cleanup() }
        // Probe the tested app's permission without presenting a privacy prompt.
        let probe = try fixture.process(fixture.executable, [
            "--capture", "screenshot", "--target", "display", "--drafts-dir", fixture.root.appendingPathComponent("probe").path,
        ])
        XCTAssertEqual(probe.exitCode, 0, "Required real capture preflight failed: \(probe.stdout) \(probe.stderr)")
        guard probe.exitCode == 0 else { return }
        fixture.launch()
        fixture.openStatusMenu()
        fixture.clickStatusEntry("Capture Image")
        let canvas = fixture.app.groups["annotation-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        XCTAssertTrue(canvas.label.contains("capture-1.png"))
        let draft = try XCTUnwrap(fixture.drafts.current())
        XCTAssertEqual(draft.bundle.media.count, 1)
        let media = try XCTUnwrap(draft.bundle.media.first)
        let pixels = try ImageFiles.pixelSize(of: draft.mediaURL(media))
        XCTAssertEqual(pixels.width, media.pixelWidth)
        XCTAssertEqual(pixels.height, media.pixelHeight)
        XCTAssertGreaterThan(pixels.width, 0)
        capture("real-screen-capture-editor", fixture.app.windows.containing(.group, identifier: "annotation-canvas").firstMatch)
    }

    private func captureConfirmation(_ name: String, _ app: XCUIApplication) {
        let confirmation = app.staticTexts["filed-confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        capture(name, app.descendants(matching: .any)["filed-hud"])
    }

    private func captureDetails(_ name: String, _ session: XCUIElement) {
        let form = session.scrollViews.firstMatch
        form.scroll(byDeltaX: 0, deltaY: -650)
        XCTAssertTrue(session.buttons["session-ticket-text"].isHittable)
        session.buttons["session-submit"].hover()
        XCTAssertTrue(session.buttons["_XCUI:CloseWindow"].isHittable)
        capture(name, form)
    }

    private func controlValue(_ element: XCUIElement) -> String {
        if let number = element.value as? NSNumber { return number.stringValue }
        return element.value as? String ?? "<no value>"
    }

    private func replace(_ element: XCUIElement, with text: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(text)
    }

    private func resize(_ window: XCUIElement, to size: CGSize) {
        let frame = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.click(
            forDuration: 0.2,
            thenDragTo: corner.withOffset(CGVector(dx: size.width - frame.width, dy: size.height - frame.height))
        )
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(window.frame.width - size.width) < 4 && abs(window.frame.height - size.height) < 4
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

    private func capture(_ name: String, _ element: XCUIElement) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
