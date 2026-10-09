import CoreGraphics
import Testing
@testable import UXReviewKit

/// HS2-AH6HW4: the resizable capture sidebar. Spec: docs/06-annotation-editor.md §6.1.
struct MediaStripWidthTests {
    @Test func widthsStayInRangeAndThumbnailsFollow() {
        #expect(MediaStripWidth.clamped(112) == 112)
        #expect(MediaStripWidth.clamped(10) == MediaStripWidth.minimum)
        #expect(MediaStripWidth.clamped(5000) == MediaStripWidth.maximum)
        #expect(MediaStripWidth.clamped(.nan) == MediaStripWidth.standard)
        #expect(MediaStripWidth.clamped(.infinity) == MediaStripWidth.standard)
        // The standard strip keeps the original 88 × 60 thumbnails.
        #expect(MediaStripWidth.thumbnail(for: 112) == CGSize(width: 88, height: 60))
        #expect(MediaStripWidth.thumbnail(for: 224) == CGSize(width: 200, height: 136))
        #expect(MediaStripWidth.thumbnail(for: 1) == MediaStripWidth.thumbnail(for: MediaStripWidth.minimum))
    }

    /// HS2-RZVDEQ: in a narrow window the strip gives way, so the canvas and inspector keep their
    /// room; the saved width is untouched and comes back as the window widens.
    @Test func theStripNarrowsToFitTheWindow() {
        // The 900-point minimum window leaves 178 points (canvas 420, inspector 300, dividers).
        #expect(MediaStripWidth.fitted(320, available: 178) == 178)
        #expect(MediaStripWidth.fitted(112, available: 178) == 112)
        #expect(MediaStripWidth.fitted(320, available: 1000) == MediaStripWidth.maximum)
        // Never below the minimum, and a bad width is still the standard one.
        #expect(MediaStripWidth.fitted(320, available: 20) == MediaStripWidth.minimum)
        #expect(MediaStripWidth.fitted(.nan, available: 178) == MediaStripWidth.standard)
        #expect(MediaStripWidth.fitted(.nan, available: 50) == MediaStripWidth.minimum)
        // No width known yet (first layout pass): just the clamped width.
        #expect(MediaStripWidth.fitted(5000, available: .infinity) == MediaStripWidth.maximum)
        // Narrow, then wide again: the same saved width fits each time.
        let sequence: [(available: CGFloat, expected: CGFloat)] = [(178, 178), (600, 240), (178, 178), (1000, 240)]
        for (available, expected) in sequence {
            #expect(MediaStripWidth.fitted(240, available: available) == expected)
        }
    }

    /// A drag past either end sticks at it, and dragging back from there moves at once (the
    /// drag is measured from where it started, not from the clamped width).
    @Test func dragsClampAtBothEndsAndComeBack() {
        let start = MediaStripWidth.standard
        #expect(MediaStripWidth.dragged(from: start, by: 40) == 152)
        #expect(MediaStripWidth.dragged(from: start, by: -500) == MediaStripWidth.minimum)
        #expect(MediaStripWidth.dragged(from: start, by: 900) == MediaStripWidth.maximum)
        #expect(MediaStripWidth.dragged(from: start, by: 0) == start)
        // Past the minimum and back within one drag.
        #expect(MediaStripWidth.dragged(from: start, by: -30) == 96)
        #expect(MediaStripWidth.dragged(from: start, by: 10) == 122)
        // A second drag starts from where the first ended.
        let after = MediaStripWidth.dragged(from: start, by: 900)
        #expect(MediaStripWidth.dragged(from: after, by: -100) == MediaStripWidth.maximum - 100)
    }
}
