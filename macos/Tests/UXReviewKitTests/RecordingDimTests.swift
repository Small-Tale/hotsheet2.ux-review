import CoreGraphics
import Testing
@testable import UXReviewKit

/// HS2-122ZFZ: the dim around a region being recorded (docs/04 §4.9).
struct RecordingDimTests {
    static let display = CGSize(width: 1440, height: 900)
    static let bounds = CGRect(origin: .zero, size: display)

    static func area(_ rects: [CGRect]) -> CGFloat { rects.reduce(0) { $0 + $1.width * $1.height } }

    /// The bands never overlap each other or the hole, and with the hole they tile the bounds.
    static func expectTiles(_ rects: [CGRect], hole: CGRect, bounds: CGRect) {
        for (index, rect) in rects.enumerated() {
            #expect(bounds.contains(rect), "band \(rect) leaves the display")
            #expect(!rect.intersects(hole), "band \(rect) covers the recorded area")
            for other in rects[(index + 1)...] {
                #expect(!rect.intersects(other), "bands \(rect) and \(other) overlap")
            }
        }
        let clear = hole.intersection(bounds)
        let clearArea = clear.isNull ? 0 : clear.width * clear.height
        #expect(abs(area(rects) + clearArea - bounds.width * bounds.height) < 0.001)
    }

    @Test func aRegionInTheMiddleGetsFourBandsAndFlipsToViewCoordinates() throws {
        // Display-local, top-left: 100 pt from the left, 200 pt from the top, 400×300, at 2x.
        let region = DisplayRegion(sourceRect: CGRect(x: 100, y: 200, width: 400, height: 300), pixelWidth: 800, pixelHeight: 600)
        let layout = try #require(RecordingDim.layout(region: region, displaySize: Self.display))
        // In the bottom-left view: y = 900 - (200 + 300) = 400.
        #expect(layout.hole == CGRect(x: 100, y: 400, width: 400, height: 300))
        #expect(layout.dimRects == [
            CGRect(x: 0, y: 0, width: 1440, height: 400), // below
            CGRect(x: 0, y: 700, width: 1440, height: 200), // above
            CGRect(x: 0, y: 400, width: 100, height: 300), // left
            CGRect(x: 500, y: 400, width: 940, height: 300), // right
        ])
        Self.expectTiles(layout.dimRects, hole: layout.hole, bounds: Self.bounds)
        // The outline's stroke lies just outside the hole.
        let half = RecordingDim.outlineWidth / 2
        #expect(layout.outline == layout.hole.insetBy(dx: -half, dy: -half))
        #expect(layout.outline.insetBy(dx: half, dy: half) == layout.hole)
    }

    @Test func usesTheEvenSizedAreaThatIsActuallyRecorded() throws {
        // 401×301 px at 1x is recorded as 400×300.
        let region = DisplayRegion(sourceRect: CGRect(x: 10, y: 20, width: 401, height: 301), pixelWidth: 401, pixelHeight: 301)
        let layout = try #require(RecordingDim.layout(region: region, displaySize: Self.display))
        #expect(layout.hole == CGRect(x: 10, y: 900 - 20 - 300, width: 400, height: 300))
        Self.expectTiles(layout.dimRects, hole: layout.hole, bounds: Self.bounds)
    }

    @Test func regionsTouchingEdgesDropEmptyBands() throws {
        let cases: [(CGRect, Int)] = [
            (CGRect(x: 0, y: 0, width: 400, height: 300), 2), // top-left corner: right + below
            (CGRect(x: 0, y: 0, width: 1440, height: 300), 1), // full-width strip at the top: below
            (CGRect(x: 1040, y: 600, width: 400, height: 300), 2), // bottom-right corner
            (CGRect(x: 0, y: 100, width: 1440, height: 300), 2), // full-width strip: above + below
            (CGRect(x: 0, y: 0, width: 1440, height: 900), 0), // the whole display: nothing to dim
        ]
        for (rect, expected) in cases {
            let region = DisplayRegion(sourceRect: rect, pixelWidth: Int(rect.width) * 2, pixelHeight: Int(rect.height) * 2)
            let layout = try #require(RecordingDim.layout(region: region, displaySize: Self.display))
            #expect(layout.dimRects.count == expected, "\(rect)")
            Self.expectTiles(layout.dimRects, hole: layout.hole, bounds: Self.bounds)
        }
    }

    @Test func regionsPartlyOrWhollyOffTheDisplay() throws {
        // Partly off the right edge: clipped.
        let partly = DisplayRegion(sourceRect: CGRect(x: 1300, y: 100, width: 400, height: 200), pixelWidth: 400, pixelHeight: 200)
        let layout = try #require(RecordingDim.layout(region: partly, displaySize: Self.display))
        #expect(layout.hole == CGRect(x: 1300, y: 600, width: 140, height: 200))
        Self.expectTiles(layout.dimRects, hole: layout.hole, bounds: Self.bounds)
        // Wholly off the display: no dim at all rather than a fully dark screen.
        let off = DisplayRegion(sourceRect: CGRect(x: 2000, y: 100, width: 400, height: 200), pixelWidth: 400, pixelHeight: 200)
        #expect(RecordingDim.layout(region: off, displaySize: Self.display) == nil)
    }

    @Test func dimRectsHandleDegenerateInputs() {
        // A hole outside the bounds dims everything; empty bounds dim nothing.
        #expect(RecordingDim.dimRects(around: CGRect(x: 5000, y: 0, width: 10, height: 10), in: Self.bounds) == [Self.bounds])
        #expect(RecordingDim.dimRects(around: .zero, in: Self.bounds) == [Self.bounds])
        #expect(RecordingDim.dimRects(around: CGRect(x: 1, y: 1, width: 5, height: 5), in: .zero).isEmpty)
        // A hole given with negative size is standardized.
        let reversed = CGRect(x: 500, y: 400, width: -100, height: -100)
        let rects = RecordingDim.dimRects(around: reversed, in: Self.bounds)
        Self.expectTiles(rects, hole: reversed.standardized, bounds: Self.bounds)
        // Non-zero origin bounds (a secondary display's view is still zero-based, but the
        // band math must not assume it).
        let offset = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let hole = CGRect(x: -1000, y: 500, width: 200, height: 100)
        Self.expectTiles(RecordingDim.dimRects(around: hole, in: offset), hole: hole, bounds: offset)
    }

    @Test func dimIsSlightNotOpaque() {
        #expect(RecordingDim.dimAlpha >= 0.25 && RecordingDim.dimAlpha <= 0.35)
        #expect(RecordingDim.outlineWidth > 0 && RecordingDim.outlineWidth <= 2)
    }
}
