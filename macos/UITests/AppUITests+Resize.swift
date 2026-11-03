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
        // a drag of about 5 pt or less is ignored, so correct each side with an edge-midpoint drag
        // that grows past the target and then a fixed shrink back to it, both well above that
        // threshold. Callers needing an exact width use resizeToMinimumWidth instead.
        for pass in 1 ... 3 {
            if waitForSize(window, size, timeout: pass == 1 ? 2 : 1) { return }
            let widthDelta = size.width - window.frame.width
            if abs(widthDelta) >= 2 {
                dragEdge(window, at: CGVector(dx: 1, dy: 0.5), inset: CGVector(dx: -1, dy: 0), by: CGVector(dx: widthDelta, dy: 0))
            }
            let heightDelta = size.height - window.frame.height
            if abs(heightDelta) >= 2 {
                dragEdge(window, at: CGVector(dx: 0.5, dy: 1), inset: CGVector(dx: 0, dy: -1), by: CGVector(dx: 0, dy: heightDelta))
            }
            history.append("edges#\(pass) \(window.frame.size)")
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

    private func dragEdge(_ window: XCUIElement, at edge: CGVector, inset: CGVector, by delta: CGVector) {
        let overshoot: CGFloat = 30
        let grow = CGVector(dx: delta.dx == 0 ? 0 : delta.dx + overshoot, dy: delta.dy == 0 ? 0 : delta.dy + overshoot)
        let shrink = CGVector(dx: delta.dx == 0 ? 0 : -overshoot, dy: delta.dy == 0 ? 0 : -overshoot)
        for step in [grow, shrink] {
            let start = window.coordinate(withNormalizedOffset: edge).withOffset(inset)
            start.click(forDuration: 0.2, thenDragTo: start.withOffset(step), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    private func waitForSize(_ window: XCUIElement, _ size: CGSize, timeout: TimeInterval) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(window.frame.width - size.width) < 4 && abs(window.frame.height - size.height) < 4
        }, object: nil)
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }
}
