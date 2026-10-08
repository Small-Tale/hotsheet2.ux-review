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
