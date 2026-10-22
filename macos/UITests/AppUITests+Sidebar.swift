import UXReviewKit
import XCTest

extension AppUITests {
    func testSidebarWidthPersistsAndFollowsExternalChanges() throws {
        continueAfterFailure = false
        let fixture = try UIAppFixture()
        addTeardownBlock { await fixture.cleanup() }
        _ = try fixture.run(fixture.executable, ["--import", fixture.image.path])
        fixture.launch()
        _ = fixture.openEditor()
        let editor = fixture.app.windows.containing(.group, identifier: "annotation-canvas").firstMatch
        resize(editor, to: CGSize(width: 1200, height: 700))
        let divider = editor.descendants(matching: .any)["editor-strip-divider"]
        assertStripWidth(112, divider: divider, editor: editor, fixture: fixture)
        XCTAssertTrue(divider.isEnabled)
        captureSidebarHierarchy("sidebar-accessibility-enabled", editor: editor)
        dragStrip(divider, by: 80)
        assertStripWidth(192, divider: divider, editor: editor, fixture: fixture)
        XCTAssertTrue(fixture.wait { fixture.defaults.double(forKey: "editorMediaStripWidth") == 192 })
        fixture.defaults.set(256.0, forKey: "editorMediaStripWidth")
        assertStripWidth(256, divider: divider, editor: editor, fixture: fixture)
        capture("sidebar-external-wide", editor)
        resize(editor, to: CGSize(width: 900, height: 620))
        XCTAssertTrue(fixture.wait {
            (96 ... 180).contains(self.shownStripWidth(divider, in: editor))
        })
        XCTAssertEqual(fixture.defaults.double(forKey: "editorMediaStripWidth"), 256)
        capture("sidebar-fitted-narrow", editor)
        resize(editor, to: CGSize(width: 1200, height: 700))
        assertStripWidth(256, divider: divider, editor: editor, fixture: fixture)
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        assertStripWidth(112, divider: divider, editor: editor, fixture: fixture)
        XCTAssertTrue(fixture.wait { fixture.defaults.double(forKey: "editorMediaStripWidth") == 112 })
        capture("sidebar-reset-wide", editor)
        fixture.defaults.set(nil, forKey: "editorMediaStripWidth")
        assertStripWidth(112, divider: divider, editor: editor, fixture: fixture)
        fixture.defaults.set(224.0, forKey: "editorMediaStripWidth")
        assertStripWidth(224, divider: divider, editor: editor, fixture: fixture)
        dragStrip(divider, by: -64)
        assertStripWidth(160, divider: divider, editor: editor, fixture: fixture)
        XCTAssertTrue(fixture.wait { fixture.defaults.double(forKey: "editorMediaStripWidth") == 160 })
        fixture.app.terminate()
        fixture.launch()
        _ = fixture.openEditor()
        assertStripWidth(160, divider: divider, editor: editor, fixture: fixture)
        capture("sidebar-persisted-relaunch", editor)
    }

    private func assertStripWidth(_ width: Int, divider: XCUIElement, editor: XCUIElement, fixture: UIAppFixture) {
        XCTAssertTrue(
            fixture.wait { divider.exists && abs(self.shownStripWidth(divider, in: editor) - CGFloat(width)) <= 1 },
            "Expected sidebar width \(width), got \(shownStripWidth(divider, in: editor))"
        )
    }

    private func shownStripWidth(_ divider: XCUIElement, in editor: XCUIElement) -> CGFloat {
        // The nine-point hit target centers on the one-point divider after the strip.
        divider.frame.midX - editor.frame.minX - 0.5
    }

    private func dragStrip(_ divider: XCUIElement, by delta: CGFloat) {
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: delta, dy: 0)))
    }
}
