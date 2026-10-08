import CoreGraphics
import Testing
@testable import UXReviewKit

/// Restored window frames kept on screen (`HS2-VX8T5A`). Spec: docs/05-start-and-settings.md §5.1.1.
struct WindowFrameFitTests {
    /// A 1728 × 1084 laptop screen below a 33 pt menu bar.
    static let visible = CGRect(x: 0, y: 0, width: 1728, height: 1051)

    @Test func aFrameThatFitsIsUntouched() {
        let frame = CGRect(x: 544, y: 300, width: 640, height: 492)
        #expect(WindowFrameFit.fit(frame, in: Self.visible) == frame)
        // Exactly the visible area fits too.
        #expect(WindowFrameFit.fit(Self.visible, in: Self.visible) == Self.visible)
    }

    /// The saved Submit Review frame from the bug: 2042 pt tall, hanging 958 pt below the screen.
    @Test func aFrameTallerThanTheScreenShrinksToIt() {
        let fitted = WindowFrameFit.fit(CGRect(x: 544, y: -958, width: 640, height: 2042), in: Self.visible)
        #expect(fitted == CGRect(x: 544, y: 0, width: 640, height: 1051))
    }

    /// With the window's opening size given, the bug's 2042 pt frame goes back to 712 pt (680 pt of
    /// content plus the title bar), its top at the top of the screen; the width, which fits, stays.
    @Test func anOversizedSideGoesBackToTheOpeningSize() {
        let opening = CGSize(width: 640, height: 712)
        let fitted = WindowFrameFit.fit(CGRect(x: 544, y: -958, width: 900, height: 2042), in: Self.visible, defaultSize: opening)
        #expect(fitted == CGRect(x: 544, y: 339, width: 900, height: 712))
        // An opening size larger than the screen is cut to the screen; the minimum still wins.
        let huge = WindowFrameFit.fit(
            CGRect(x: 0, y: 0, width: 640, height: 3000), in: Self.visible, defaultSize: CGSize(width: 640, height: 5000)
        )
        #expect(huge.height == 1051)
        let small = WindowFrameFit.fit(
            CGRect(x: 0, y: 0, width: 640, height: 3000), in: Self.visible,
            minSize: CGSize(width: 560, height: 352), defaultSize: CGSize(width: 640, height: 200)
        )
        #expect(small.height == 352)
        // A frame that fits ignores the opening size.
        let fits = CGRect(x: 10, y: 10, width: 1200, height: 1000)
        #expect(WindowFrameFit.fit(fits, in: Self.visible, defaultSize: opening) == fits)
    }

    @Test func aTallFrameBelowTheScreenMovesUpInside() {
        // Too tall: it shrinks to the screen's height and moves inside.
        let fitted = WindowFrameFit.fit(CGRect(x: 100, y: -500, width: 640, height: 1400), in: Self.visible)
        #expect(fitted.size == CGSize(width: 640, height: 1051))
        #expect(fitted.minY == 0)
    }

    @Test func aFrameThatFitsInSizeButSticksOutMovesInside() {
        let below = WindowFrameFit.fit(CGRect(x: 100, y: -200, width: 640, height: 480), in: Self.visible)
        #expect(below == CGRect(x: 100, y: 0, width: 640, height: 480))
        let above = WindowFrameFit.fit(CGRect(x: 100, y: 900, width: 640, height: 480), in: Self.visible)
        #expect(above == CGRect(x: 100, y: 571, width: 640, height: 480))
        let right = WindowFrameFit.fit(CGRect(x: 1500, y: 100, width: 640, height: 480), in: Self.visible)
        #expect(right == CGRect(x: 1088, y: 100, width: 640, height: 480))
        let left = WindowFrameFit.fit(CGRect(x: -300, y: 100, width: 640, height: 480), in: Self.visible)
        #expect(left == CGRect(x: 0, y: 100, width: 640, height: 480))
    }

    /// A frame left on a display that's gone (far off every edge) comes back whole.
    @Test func aFrameOnAMissingDisplayComesBack() {
        let fitted = WindowFrameFit.fit(CGRect(x: 4000, y: 2500, width: 1240, height: 800), in: Self.visible)
        #expect(fitted == CGRect(x: 488, y: 251, width: 1240, height: 800))
    }

    @Test func aWideFrameShrinksToTheScreenWidth() {
        let fitted = WindowFrameFit.fit(CGRect(x: -50, y: 0, width: 2400, height: 800), in: Self.visible)
        #expect(fitted == CGRect(x: 0, y: 0, width: 1728, height: 800))
    }

    /// A screen smaller than the window's minimum: the minimum wins, pinned to the top left so
    /// the title bar stays reachable.
    @Test func neverBelowTheMinimumSize() {
        let small = CGRect(x: 0, y: 0, width: 800, height: 500)
        let fitted = WindowFrameFit.fit(
            CGRect(x: 0, y: 0, width: 1240, height: 800), in: small, minSize: CGSize(width: 900, height: 588)
        )
        #expect(fitted == CGRect(x: 0, y: -88, width: 900, height: 588))
    }

    /// A screen with an origin away from zero (a second display above or left of the main one).
    @Test func worksOnAnOffsetScreen() {
        let second = CGRect(x: -1920, y: 1051, width: 1920, height: 1050)
        let fitted = WindowFrameFit.fit(CGRect(x: -1000, y: 400, width: 640, height: 2000), in: second)
        #expect(fitted == CGRect(x: -1000, y: 1051, width: 640, height: 1050))
    }

    @Test func noVisibleAreaLeavesTheFrame() {
        let frame = CGRect(x: 10, y: 10, width: 640, height: 480)
        #expect(WindowFrameFit.fit(frame, in: .zero) == frame)
    }

    /// Fitting is idempotent: a second fit of a fitted frame changes nothing.
    @Test func fittingTwiceIsFittingOnce() {
        let frames = [
            CGRect(x: 544, y: -958, width: 640, height: 2042), CGRect(x: 4000, y: 2500, width: 1240, height: 800),
            CGRect(x: -50, y: 0, width: 2400, height: 800), CGRect(x: 100, y: 900, width: 640, height: 480),
        ]
        for frame in frames {
            let once = WindowFrameFit.fit(frame, in: Self.visible)
            #expect(WindowFrameFit.fit(once, in: Self.visible) == once)
            #expect(Self.visible.contains(once))
        }
    }
}
