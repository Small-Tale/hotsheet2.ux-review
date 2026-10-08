import CoreGraphics
import Testing
@testable import UXReviewKit

extension RegionGeometryTests {
    /// HS2-DX2D41: a point is converted through the window its event belongs to, whichever
    /// display's overlay receives it, so hover resolves the same point a click would.
    @Test func eventPointsUseTheEventsOwnWindow() {
        let local = CGPoint(x: 100, y: 50)
        let mouse = CGPoint(x: 7, y: 7)
        // The event belongs to the secondary overlay (received by either overlay's view).
        let onSecondary = RegionGeometry.globalPoint(locationInWindow: local, eventWindowFrame: secondary.frame, mouseLocation: mouse)
        #expect(onSecondary == CGPoint(x: 1540, y: -130))
        #expect(RegionGeometry.screenIndex(containing: onSecondary, in: [primary, secondary]) == 1)
        // The same window-relative location on the primary overlay is a different global point.
        let onPrimary = RegionGeometry.globalPoint(locationInWindow: local, eventWindowFrame: primary.frame, mouseLocation: mouse)
        #expect(onPrimary == local)
        #expect(RegionGeometry.screenIndex(containing: onPrimary, in: [primary, secondary]) == 0)
        // No window (an event synthesized without one): the global mouse location.
        #expect(RegionGeometry.globalPoint(locationInWindow: local, eventWindowFrame: nil, mouseLocation: mouse) == mouse)
    }
}
