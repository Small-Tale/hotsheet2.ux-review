import XCTest

/// Window resizing for live UI tests (HS2-GR8A2A).
extension AppUITests {
    func resize(_ window: XCUIElement, to size: CGSize) {
        let frame = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.click(
            forDuration: 0.2,
            thenDragTo: corner.withOffset(CGVector(dx: size.width - frame.width, dy: size.height - frame.height)),
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )
        var history = ["corner \(window.frame.size)"]
        // HS2-GR8A2A: on the isolated macOS VM a drag lands within a few points of its target and
        // a drag of about 5 pt or less is ignored, so each correction grows past the target and
        // then shrinks a fixed amount back, both well above that threshold. HS2-3AVG0K: the
        // corrections use the corner too; an edge drag 1 pt inside the window can land on an
        // always-visible scroller and resize nothing. Callers needing an exact width use
        // resizeToMinimumWidth instead.
        for pass in 1 ... 3 {
            if waitForSize(window, size, timeout: pass == 1 ? 2 : 1) { return }
            let delta = CGVector(dx: size.width - window.frame.width, dy: size.height - window.frame.height)
            correctCorner(window, by: CGVector(dx: abs(delta.dx) > 4 ? delta.dx : 0, dy: abs(delta.dy) > 4 ? delta.dy : 0))
            history.append("corner#\(pass) \(window.frame.size)")
        }
        XCTAssertTrue(waitForSize(window, size, timeout: 2), "Window never reached \(size): \(history.joined(separator: ", "))")
    }

    /// Drags the right edge well past `minimum` so the window clamps to exactly its minimum
    /// width, independent of pointer precision (HS2-GR8A2A), and asserts that width.
    func resizeToMinimumWidth(_ window: XCUIElement, minimum: CGFloat) {
        let right = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -1, dy: 0))
        right.click(
            forDuration: 0.2,
            thenDragTo: right.withOffset(CGVector(dx: minimum - window.frame.width - 60, dy: 0)),
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )
        let clamped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(window.frame.width - minimum) < 0.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [clamped], timeout: 5), .completed, "Window width \(window.frame.width); minimum \(minimum)")
    }

    /// Grows past the target by `delta` plus an overshoot on each axis that needs it, then
    /// shrinks back by the overshoot, through the bottom-right corner (HS2-3AVG0K).
    private func correctCorner(_ window: XCUIElement, by delta: CGVector) {
        let overshoot: CGFloat = 30
        let grow = CGVector(dx: delta.dx == 0 ? 0 : delta.dx + overshoot, dy: delta.dy == 0 ? 0 : delta.dy + overshoot)
        let shrink = CGVector(dx: delta.dx == 0 ? 0 : -overshoot, dy: delta.dy == 0 ? 0 : -overshoot)
        for step in [grow, shrink] where step != .zero {
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
            corner.click(forDuration: 0.2, thenDragTo: corner.withOffset(step), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    private func waitForSize(_ window: XCUIElement, _ size: CGSize, timeout: TimeInterval) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(window.frame.width - size.width) <= 4 && abs(window.frame.height - size.height) <= 4
        }, object: nil)
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }
}
