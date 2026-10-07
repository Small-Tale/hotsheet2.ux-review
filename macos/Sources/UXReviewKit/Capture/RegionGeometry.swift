import CoreGraphics
import Foundation

/// One display as the capture code sees it.
public struct ScreenGeometry: Equatable, Sendable {
    /// Frame in AppKit global coordinates: points, origin at the bottom-left of the primary display.
    public var frame: CGRect
    /// Backing scale factor (pixels per point).
    public var scale: Double

    public init(frame: CGRect, scale: Double) {
        self.frame = frame
        self.scale = scale
    }
}

/// A capture area on one display, ready for ScreenCaptureKit.
public struct DisplayRegion: Equatable, Sendable {
    /// Display-local points with a top-left origin (`SCStreamConfiguration.sourceRect`).
    public var sourceRect: CGRect
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(sourceRect: CGRect, pixelWidth: Int, pixelHeight: Int) {
        self.sourceRect = sourceRect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Coordinate math for region capture. AppKit reports a dragged region in global, bottom-left
/// coordinates; ScreenCaptureKit wants display-local, top-left points snapped to whole pixels.
public enum RegionGeometry {
    /// Regions smaller than this many points on either side are treated as an accidental click.
    public static let minimumSide: CGFloat = 4

    /// The rectangle spanned by a drag, whichever direction it went.
    public static func dragRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// The screen containing `point` (AppKit global coordinates), if any. Frames are half-open,
    /// so a point on the shared edge of two side-by-side displays belongs to the right one.
    public static func screenIndex(containing point: CGPoint, in screens: [ScreenGeometry]) -> Int? {
        screens.firstIndex { $0.frame.contains(point) }
    }

    /// Converts a region in AppKit global coordinates to a capture area on `screen`, clipped to
    /// the screen. Returns nil when what is left is smaller than `minimumSide`.
    public static func displayRegion(forGlobal rect: CGRect, on screen: ScreenGeometry) -> DisplayRegion? {
        let clipped = rect.standardized.intersection(screen.frame)
        guard !clipped.isNull else { return nil }
        let local = CGRect(
            x: clipped.minX - screen.frame.minX,
            y: screen.frame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
        return displayRegion(forLocal: local, displaySize: screen.frame.size, scale: screen.scale)
    }

    /// Clips a display-local, top-left rectangle (points) to the display and snaps it outward to
    /// whole pixels. Returns nil when the clipped area is smaller than `minimumSide`.
    public static func displayRegion(forLocal rect: CGRect, displaySize: CGSize, scale: Double) -> DisplayRegion? {
        guard scale > 0 else { return nil }
        let bounds = CGRect(origin: .zero, size: displaySize)
        let clipped = rect.standardized.intersection(bounds)
        guard !clipped.isNull, clipped.width >= minimumSide, clipped.height >= minimumSide else { return nil }
        // Snap outward to the pixel grid so the capture never cuts a pixel in half, then clamp
        // again in case snapping crossed the display edge.
        let maxPixelX = (Double(displaySize.width) * scale).rounded(.down)
        let maxPixelY = (Double(displaySize.height) * scale).rounded(.down)
        let minX = max((Double(clipped.minX) * scale).rounded(.down), 0)
        let minY = max((Double(clipped.minY) * scale).rounded(.down), 0)
        let maxX = min((Double(clipped.maxX) * scale).rounded(.up), maxPixelX)
        let maxY = min((Double(clipped.maxY) * scale).rounded(.up), maxPixelY)
        let pixelWidth = Int(maxX - minX)
        let pixelHeight = Int(maxY - minY)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return DisplayRegion(
            sourceRect: CGRect(x: minX / scale, y: minY / scale, width: Double(pixelWidth) / scale, height: Double(pixelHeight) / scale),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    /// Pixel size for capturing `size` points at `scale`, at least 1×1.
    public static func pixelSize(points size: CGSize, scale: Double) -> (width: Int, height: Int) {
        (max(Int((Double(size.width) * scale).rounded()), 1), max(Int((Double(size.height) * scale).rounded()), 1))
    }
}
