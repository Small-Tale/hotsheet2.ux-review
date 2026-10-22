import ApplicationServices
import UXReviewKit
import XCTest

extension AppUITests {
    func testSidebarAnnouncesWidthAndSupportsAccessibilityActions() throws {
        continueAfterFailure = false
        let fixture = try UIAppFixture()
        addTeardownBlock { await fixture.cleanup() }
        _ = try fixture.run(fixture.executable, ["--import", fixture.image.path])
        fixture.launch()
        _ = fixture.openEditor()
        let editor = fixture.app.windows.containing(.group, identifier: "annotation-canvas").firstMatch
        resize(editor, to: CGSize(width: 1200, height: 700))
        let slider = editor.sliders["editor-strip-divider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), editor.debugDescription)
        XCTAssertTrue(slider.isEnabled)
        assertAnnouncedWidth(112, slider: slider, fixture: fixture)
        captureSidebarHierarchy("sidebar-accessibility-after", editor: editor)
        try fixture.adjustSidebar(kAXIncrementAction as CFString)
        assertAnnouncedWidth(128, slider: slider, fixture: fixture)
        try fixture.adjustSidebar(kAXDecrementAction as CFString)
        assertAnnouncedWidth(112, slider: slider, fixture: fixture)
        fixture.defaults.set(224.0, forKey: "editorMediaStripWidth")
        assertAnnouncedWidth(224, slider: slider, fixture: fixture)
        capture("sidebar-accessible-wide", editor)
        try fixture.adjustSidebar(kAXIncrementAction as CFString)
        assertAnnouncedWidth(240, slider: slider, fixture: fixture)
        try fixture.adjustSidebar(kAXDecrementAction as CFString)
        assertAnnouncedWidth(224, slider: slider, fixture: fixture)
        try checkSidebarAccessibilityBounds(slider, editor: editor, fixture: fixture)
        captureSidebarHierarchy("sidebar-accessibility-after-actions", editor: editor)
    }

    func captureSidebarHierarchy(_ name: String, editor: XCUIElement) {
        let tree = XCTAttachment(string: editor.debugDescription)
        tree.name = name
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func checkSidebarAccessibilityBounds(_ slider: XCUIElement, editor: XCUIElement, fixture: UIAppFixture) throws {
        fixture.defaults.set(96.0, forKey: "editorMediaStripWidth")
        assertAnnouncedWidth(96, slider: slider, fixture: fixture)
        try fixture.adjustSidebar(kAXDecrementAction as CFString)
        assertAnnouncedWidth(96, slider: slider, fixture: fixture)
        fixture.defaults.set(320.0, forKey: "editorMediaStripWidth")
        assertAnnouncedWidth(320, slider: slider, fixture: fixture)
        try fixture.adjustSidebar(kAXIncrementAction as CFString)
        assertAnnouncedWidth(320, slider: slider, fixture: fixture)
        resize(editor, to: CGSize(width: 900, height: 620))
        XCTAssertTrue(fixture.wait { slider.value as? String == "178 points" })
        capture("sidebar-accessible-narrow", editor)
        try fixture.adjustSidebar(kAXDecrementAction as CFString)
        assertAnnouncedWidth(162, slider: slider, fixture: fixture)
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        assertAnnouncedWidth(112, slider: slider, fixture: fixture)
        fixture.defaults.set(nil, forKey: "editorMediaStripWidth")
        XCTAssertTrue(fixture.wait { slider.value as? String == "112 points" })
        try fixture.adjustSidebar(kAXIncrementAction as CFString)
        assertAnnouncedWidth(128, slider: slider, fixture: fixture)
    }

    private func assertAnnouncedWidth(_ width: Int, slider: XCUIElement, fixture: UIAppFixture) {
        XCTAssertTrue(
            fixture.wait { slider.value as? String == "\(width) points" },
            "Unexpected slider value: \(String(describing: slider.value))"
        )
        if width != 112 || fixture.defaults.double(forKey: "editorMediaStripWidth") != nil {
            XCTAssertTrue(fixture.wait { fixture.defaults.double(forKey: "editorMediaStripWidth") == Double(width) })
        }
    }
}
