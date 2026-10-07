import CoreGraphics
import Foundation

/// Geometry of the dim shown around a region while it is being recorded (docs/04 §4.9,
/// HS2-122ZFZ). Everything outside the recorded area is covered by up to four non-overlapping
/// bands; the area itself stays clear, with a thin outline just outside it.
public enum RecordingDim {
    /// Opacity of the black dim outside the region.
    public static let dimAlpha: Double = 0.3
    /// Width of the outline drawn just outside the region (points).
    public static let outlineWidth: CGFloat = 1

    public struct Layout: Equatable, Sendable {
        /// The recorded area in the overlay view's coordinates (bottom-left origin, points),
        /// clipped to the display.
        public var hole: CGRect
        /// Non-overlapping bands that together cover the display minus `hole`.
        public var dimRects: [CGRect]
        /// The path to stroke with `outlineWidth`, centered so the stroke lies entirely outside
        /// `hole`.
        public var outline: CGRect
    }

    /// The dim layout for recording `region` (display-local, top-left origin, as given to
    /// ScreenCaptureKit) on a display of `displaySize` points. Uses the even-sized area that is
    /// actually recorded. Returns nil when the region does not overlap the display.
    public static func layout(region: DisplayRegion, displaySize: CGSize) -> Layout? {
        let recorded = region.evenSized.sourceRect
        let bounds = CGRect(origin: .zero, size: displaySize)
        // Flip from the display's top-left origin to the view's bottom-left origin.
        let flipped = CGRect(
            x: recorded.minX,
            y: displaySize.height - recorded.maxY,
            width: recorded.width,
            height: recorded.height
        )
        let hole = flipped.standardized.intersection(bounds)
        guard !hole.isNull, hole.width > 0, hole.height > 0 else { return nil }
        let inset = -outlineWidth / 2
        return Layout(
            hole: hole,
            dimRects: dimRects(around: hole, in: bounds),
            outline: hole.insetBy(dx: inset, dy: inset)
        )
    }

    /// Bands covering `bounds` minus `hole`: below and above span the full width; left and
    /// right fill the hole's height. Empty bands are dropped, so a hole touching an edge gives
    /// fewer bands and a hole covering everything gives none. A hole outside `bounds` leaves
    /// `bounds` fully dimmed.
    public static func dimRects(around hole: CGRect, in bounds: CGRect) -> [CGRect] {
        let clear = hole.standardized.intersection(bounds)
        guard !clear.isNull, clear.width > 0, clear.height > 0 else { return bounds.isEmpty ? [] : [bounds] }
        let bands = [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: clear.minY - bounds.minY),
            CGRect(x: bounds.minX, y: clear.maxY, width: bounds.width, height: bounds.maxY - clear.maxY),
            CGRect(x: bounds.minX, y: clear.minY, width: clear.minX - bounds.minX, height: clear.height),
            CGRect(x: clear.maxX, y: clear.minY, width: bounds.maxX - clear.maxX, height: clear.height),
        ]
        return bands.filter { $0.width > 0 && $0.height > 0 }
    }
}
