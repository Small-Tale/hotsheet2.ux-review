import CoreGraphics
import Testing
@testable import UXReviewKit

struct CanvasViewportTests {
    // A 5K screenshot in a 1056 x 856 canvas (1000 x 800 inside the padding) on a 2x display.
    let view = CGSize(width: 1056, height: 856)
    let media = CGSize(width: 5120, height: 2880)
    let backing: CGFloat = 2

    private func layout(_ viewport: CanvasViewport, view: CGSize? = nil, media: CGSize? = nil) throws -> CanvasViewport.Layout {
        try #require(viewport.layout(view: view ?? self.view, media: media ?? self.media))
    }

    /// Where a media pixel is drawn.
    private func viewPoint(_ pixel: CGPoint, _ layout: CanvasViewport.Layout) -> CGPoint {
        CGPoint(x: layout.imageRect.minX + pixel.x * layout.scale, y: layout.imageRect.minY + pixel.y * layout.scale)
    }

    @Test func fitsAndCentersByDefault() throws {
        let fit = try layout(CanvasViewport())
        #expect(fit.scale == 1000.0 / 5120)
        #expect(fit.imageRect.midX == 528 && fit.imageRect.midY == 428)
        #expect(!fit.canPan)
        #expect(fit.percent(backingScale: backing) == 39)
        // Small media is never enlarged past 2x when fitting.
        let small = try layout(CanvasViewport(), media: CGSize(width: 100, height: 50))
        #expect(small.scale == 2)
        #expect(small.imageRect == CGRect(x: 428, y: 378, width: 200, height: 100))
        // Degenerate sizes lay out nothing.
        #expect(CanvasViewport().layout(view: CGSize(width: 40, height: 40), media: media) == nil)
        #expect(CanvasViewport().layout(view: view, media: .zero) == nil)
    }

    @Test func actualPixelsAndFit() throws {
        var viewport = CanvasViewport()
        viewport.actualPixels(view: view, media: media, backingScale: backing)
        let actual = try layout(viewport)
        #expect(actual.scale == 0.5)
        #expect(actual.percent(backingScale: backing) == 100)
        #expect(actual.center == CGPoint(x: 2560, y: 1440)) // zoomed about the middle
        #expect(actual.canPan)
        viewport.fit()
        #expect(viewport.isFit)
        #expect(try layout(viewport) == layout(CanvasViewport()))
    }

    @Test func stepsWalkTheStopsBothWaysAndClamp() throws {
        var viewport = CanvasViewport()
        var seen: [Int] = []
        for _ in 0 ..< 20 {
            viewport.step(in: true, view: view, media: media, backingScale: backing)
            seen.append(try layout(viewport).percent(backingScale: backing))
        }
        #expect(seen.prefix(10) == [50, 67, 100, 150, 200, 300, 400, 600, 800, 1200])
        #expect(seen.last == 1600) // stops at the maximum
        for _ in 0 ..< 30 {
            viewport.step(in: false, view: view, media: media, backingScale: backing)
        }
        #expect(try layout(viewport).percent(backingScale: backing) == 5) // 5 % is below the fit here
        // When the fit is smaller than 5 %, zooming out may reach the fit but not beyond.
        let huge = CGSize(width: 100_000, height: 100_000)
        var tiny = CanvasViewport()
        tiny.step(in: false, view: view, media: huge, backingScale: backing)
        #expect(try layout(tiny, media: huge).scale == layout(CanvasViewport(), media: huge).fitScale)
    }

    /// Zooming keeps the pixel under the pointer under the pointer (when not clamped).
    @Test func magnifyKeepsTheAnchorFixed() throws {
        var viewport = CanvasViewport()
        viewport.actualPixels(view: view, media: media, backingScale: backing)
        let anchor = CGPoint(x: 300, y: 250)
        let before = try layout(viewport)
        let pixel = CGPoint(x: (anchor.x - before.imageRect.minX) / before.scale, y: (anchor.y - before.imageRect.minY) / before.scale)
        viewport.magnify(by: 2.5, anchor: anchor, view: view, media: media, backingScale: backing)
        let after = try layout(viewport)
        #expect(after.scale == 1.25)
        let moved = viewPoint(pixel, after)
        #expect(abs(moved.x - anchor.x) < 0.001 && abs(moved.y - anchor.y) < 0.001)
        viewport.magnify(by: 0, anchor: anchor, view: view, media: media, backingScale: backing) // ignored
        #expect(try layout(viewport) == after)
    }

    @Test func panMovesTheMediaAndStopsAtTheEdges() throws {
        var viewport = CanvasViewport()
        viewport.actualPixels(view: view, media: media, backingScale: backing)
        let start = try layout(viewport)
        viewport.pan(by: CGVector(dx: 100, dy: -40), view: view, media: media)
        let moved = try layout(viewport)
        #expect(moved.imageRect.minX == start.imageRect.minX + 100)
        #expect(moved.imageRect.minY == start.imageRect.minY - 40)
        // Far past the top-left: the media's top-left corner stops at the padding.
        viewport.pan(by: CGVector(dx: 100_000, dy: 100_000), view: view, media: media)
        let corner = try layout(viewport)
        #expect(corner.imageRect.origin == CGPoint(x: 28, y: 28))
        // Coming back responds immediately (the stored center was clamped, not left far away).
        viewport.pan(by: CGVector(dx: -10, dy: 0), view: view, media: media)
        #expect(try layout(viewport).imageRect.minX == 18)
        // And the far edge: bottom-right corner stops at the padding.
        viewport.pan(by: CGVector(dx: -100_000, dy: -100_000), view: view, media: media)
        let far = try layout(viewport)
        #expect(far.imageRect.maxX == 1028 && far.imageRect.maxY == 828)
    }

    @Test func fittedMediaDoesNotPan() throws {
        var viewport = CanvasViewport()
        viewport.pan(by: CGVector(dx: 50, dy: 50), view: view, media: media)
        #expect(viewport == CanvasViewport())
    }

    /// Media narrower than the canvas on one axis stays centered on that axis while the other pans.
    @Test func centersTheAxisThatFits() throws {
        let tall = CGSize(width: 400, height: 6000)
        var viewport = CanvasViewport()
        viewport.actualPixels(view: view, media: tall, backingScale: backing) // 200 x 3000 points
        viewport.pan(by: CGVector(dx: 300, dy: 500), view: view, media: tall)
        let result = try layout(viewport, media: tall)
        #expect(result.imageRect.midX == 528)
        #expect(result.imageRect.minY > 428 - 1500)
    }

    /// Transition walk: zoom, resize the window, crop the media, switch to fit, zoom again.
    @Test func survivesResizeAndCropWhileZoomed() throws {
        var viewport = CanvasViewport()
        viewport.zoom(to: 1, anchor: CGPoint(x: 1000, y: 800), view: view, media: media, backingScale: backing)
        viewport.pan(by: CGVector(dx: -100_000, dy: -100_000), view: view, media: media)
        let pinned = try layout(viewport).center
        #expect(pinned == CGPoint(x: 5120 - 500, y: 2880 - 400))
        // A narrower window keeps the zoom and the pixel at the middle.
        let narrow = CGSize(width: 700, height: 500)
        let resized = try layout(viewport, view: narrow)
        #expect(resized.scale == 1)
        #expect(resized.center == pinned)
        // A wider window than the remaining media clamps instead of showing empty space.
        let wide = CGSize(width: 2056, height: 1856)
        let widened = try layout(viewport, view: wide)
        #expect(widened.imageRect.maxX == 2028 && widened.imageRect.maxY == 1828)
        // Cropping to a small image keeps the zoom and re-centers what no longer overflows.
        let cropped = CGSize(width: 300, height: 200)
        let afterCrop = try layout(viewport, view: narrow, media: cropped)
        #expect(afterCrop.scale == 1)
        #expect(afterCrop.imageRect == CGRect(x: 200, y: 150, width: 300, height: 200))
        #expect(!afterCrop.canPan)
        // Back to fit, then zooming in steps from the fit.
        viewport.fit()
        viewport.step(in: true, view: view, media: cropped, backingScale: backing)
        #expect(try layout(viewport, media: cropped).percent(backingScale: backing) == 600) // fit is 2x = 400 %
    }

    @Test func scaleRangeOnDifferentDisplays() {
        #expect(CanvasViewport.scaleRange(fitScale: 0.2, backingScale: 2) == 0.025 ... 8)
        #expect(CanvasViewport.scaleRange(fitScale: 0.2, backingScale: 1) == 0.05 ... 16)
        #expect(CanvasViewport.scaleRange(fitScale: 0.001, backingScale: 2).lowerBound == 0.001)
    }
}
