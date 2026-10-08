import CoreGraphics
import Foundation

/// Zoom and pan of the editor canvas. The canvas fits the media by default; zooming switches to
/// an explicit scale (screen points per media pixel) and a center (the media pixel shown at the
/// middle of the canvas). The view and media sizes are passed to each call rather than stored,
/// so resizing the window or cropping the image just re-lays out, clamped so the image never
/// scrolls away from the canvas. Spec: docs/06-annotation-editor.md §6.2.1.
public struct CanvasViewport: Equatable, Sendable {
    /// Room around the media inside the canvas, in points.
    public static let padding: CGFloat = 28
    /// Fitting never enlarges the media more than this (small captures stay crisp).
    public static let maxFitScale: CGFloat = 2
    /// ⌘+ / ⌘- stops, in percent of actual pixels (100 % = one media pixel per screen pixel).
    public static let stops: [Double] = [5, 10, 25, 33, 50, 67, 100, 150, 200, 300, 400, 600, 800, 1200, 1600]

    /// Points per media pixel; nil means "fit", which follows the view size.
    public private(set) var zoom: CGFloat?
    /// The media pixel at the middle of the canvas; nil means the media's center.
    public private(set) var center: CGPoint?

    public init(zoom: CGFloat? = nil, center: CGPoint? = nil) {
        self.zoom = zoom
        self.center = center
    }

    public var isFit: Bool { zoom == nil }

    public struct Layout: Equatable, Sendable {
        /// Points per media pixel.
        public var scale: CGFloat
        /// Where the media is drawn, in view coordinates (may extend past the view when zoomed).
        public var imageRect: CGRect
        public var fitScale: CGFloat
        /// The media pixel at the middle of the canvas, after clamping.
        public var center: CGPoint
        /// True when the media is larger than the canvas on some axis, so it can be panned.
        public var canPan: Bool

        /// Zoom in percent of actual pixels, given the screen's pixels per point.
        public func percent(backingScale: CGFloat) -> Int { Int((scale * backingScale * 100).rounded()) }
    }

    /// The padded area the media is laid out in; nil when the view is too small.
    static func available(in view: CGSize) -> CGRect? {
        let rect = CGRect(origin: .zero, size: view).insetBy(dx: padding, dy: padding)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    public func layout(view: CGSize, media: CGSize) -> Layout? {
        guard media.width > 0, media.height > 0, let available = Self.available(in: view) else { return nil }
        let fitScale = min(available.width / media.width, available.height / media.height, Self.maxFitScale)
        let scale = zoom ?? fitScale
        let size = CGSize(width: media.width * scale, height: media.height * scale)
        let wanted = center ?? CGPoint(x: media.width / 2, y: media.height / 2)
        func origin(_ length: CGFloat, _ available: (min: CGFloat, mid: CGFloat, max: CGFloat), _ wanted: CGFloat) -> CGFloat {
            if length <= available.max - available.min { return available.mid - length / 2 }
            return min(max(available.mid - wanted * scale, available.max - length), available.min)
        }
        let rect = CGRect(
            x: origin(size.width, (available.minX, available.midX, available.maxX), wanted.x),
            y: origin(size.height, (available.minY, available.midY, available.maxY), wanted.y),
            width: size.width,
            height: size.height
        )
        return Layout(
            scale: scale,
            imageRect: rect,
            fitScale: fitScale,
            center: CGPoint(x: (available.midX - rect.minX) / scale, y: (available.midY - rect.minY) / scale),
            canPan: size.width > available.width + 0.5 || size.height > available.height + 0.5
        )
    }

    /// The allowed scale range: down to 5 % (or the fit, if that is smaller), up to 1600 %.
    public static func scaleRange(fitScale: CGFloat, backingScale: CGFloat) -> ClosedRange<CGFloat> {
        let lower = min(stops[0] / 100 / backingScale, fitScale)
        return lower ... max(stops[stops.count - 1] / 100 / backingScale, lower)
    }

    /// Zooms to `scale`, keeping the media pixel under `anchor` (a view point; default the
    /// canvas middle) where it is.
    public mutating func zoom(to scale: CGFloat, anchor: CGPoint? = nil, view: CGSize, media: CGSize, backingScale: CGFloat) {
        guard let current = layout(view: view, media: media), let available = Self.available(in: view) else { return }
        let range = Self.scaleRange(fitScale: current.fitScale, backingScale: backingScale)
        let scale = min(max(scale, range.lowerBound), range.upperBound)
        let anchor = anchor ?? CGPoint(x: available.midX, y: available.midY)
        let pinned = CGPoint(
            x: (anchor.x - current.imageRect.minX) / current.scale,
            y: (anchor.y - current.imageRect.minY) / current.scale
        )
        let origin = CGPoint(x: anchor.x - pinned.x * scale, y: anchor.y - pinned.y * scale)
        zoom = scale
        center = CGPoint(x: (available.midX - origin.x) / scale, y: (available.midY - origin.y) / scale)
        settle(view: view, media: media)
    }

    /// Pinch: multiplies the scale, anchored at the pointer.
    public mutating func magnify(by factor: CGFloat, anchor: CGPoint?, view: CGSize, media: CGSize, backingScale: CGFloat) {
        guard let current = layout(view: view, media: media), factor > 0 else { return }
        zoom(to: current.scale * factor, anchor: anchor, view: view, media: media, backingScale: backingScale)
    }

    /// ⌘+ / ⌘-: the next stop up or down from the current zoom.
    public mutating func step(in zoomIn: Bool, anchor: CGPoint? = nil, view: CGSize, media: CGSize, backingScale: CGFloat) {
        guard let current = layout(view: view, media: media) else { return }
        let percent = current.scale * backingScale * 100
        let target: Double? = zoomIn
            ? Self.stops.first { $0 > percent * 1.001 }
            : Self.stops.last { $0 < percent * 0.999 }
        let scale = target.map { $0 / 100 / backingScale } ?? (zoomIn ? .infinity : 0)
        zoom(to: scale, anchor: anchor, view: view, media: media, backingScale: backingScale)
    }

    /// ⌘0: back to fitting the view.
    public mutating func fit() {
        zoom = nil
        center = nil
    }

    /// ⌘1: one media pixel per screen pixel, keeping the canvas middle in place.
    public mutating func actualPixels(view: CGSize, media: CGSize, backingScale: CGFloat) {
        zoom(to: 1 / backingScale, view: view, media: media, backingScale: backingScale)
    }

    /// Scrolling: moves the media by `delta` view points (clamped at its edges).
    public mutating func pan(by delta: CGVector, view: CGSize, media: CGSize) {
        guard let current = layout(view: view, media: media), current.canPan else { return } // a fitted image never overflows
        center = CGPoint(x: current.center.x - delta.dx / current.scale, y: current.center.y - delta.dy / current.scale)
        settle(view: view, media: media)
    }

    /// The canvas switched to another frame of the same media (the Crop tool shows the original,
    /// another tool the crop; or the crop changed, docs/06 §6.6): `oldOrigin` and `newOrigin` are
    /// where each frame's pixel (0, 0) lies in the original. A zoomed view keeps its scale and the
    /// same original pixel at the middle (clamped to the new frame); a fitted view stays fitted.
    public mutating func reframe(from oldOrigin: CGPoint, of oldMedia: CGSize, to newOrigin: CGPoint, of newMedia: CGSize, view: CGSize) {
        guard zoom != nil, let middle = layout(view: view, media: oldMedia)?.center else { return }
        center = CGPoint(x: middle.x + oldOrigin.x - newOrigin.x, y: middle.y + oldOrigin.y - newOrigin.y)
        settle(view: view, media: newMedia)
    }

    /// Stores the clamped center, so panning back from an edge responds at once.
    private mutating func settle(view: CGSize, media: CGSize) {
        if let layout = layout(view: view, media: media) { center = layout.center }
    }
}

/// Panning on its own while a gesture's pointer is near or past a canvas edge, so a shape can be
/// drawn, moved, or resized beyond what a zoomed canvas shows. Spec: docs/06-annotation-editor.md
/// §6.2.1.
public enum AutoScroll {
    /// How far inside the canvas edge scrolling starts, in points.
    public static let edgeZone: CGFloat = 20
    /// How far past the inner edge of the zone (out of the canvas) the speed keeps growing.
    public static let ramp: CGFloat = 100
    /// Points per second at full depth.
    public static let maxSpeed: CGFloat = 1500

    /// The pan velocity (points per second, as `CanvasViewport.pan` takes them) for a pointer at
    /// `pointer` in a canvas with `bounds`. Zero in the middle; near the right edge the media moves
    /// left to show what lies past it. Each axis is proportional to how deep the pointer is in
    /// that edge's zone, and capped.
    public static func velocity(pointer: CGPoint, in bounds: CGRect) -> CGVector {
        guard bounds.width > 2 * edgeZone, bounds.height > 2 * edgeZone else { return .zero }
        func axis(_ position: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            let towardLow = (low + edgeZone) - position
            let towardHigh = position - (high - edgeZone)
            let speed = { (depth: CGFloat) in min(depth / (edgeZone + ramp), 1) * maxSpeed }
            if towardLow > 0 { return speed(towardLow) } // near the left/top: the media moves right/down
            if towardHigh > 0 { return -speed(towardHigh) }
            return 0
        }
        return CGVector(dx: axis(pointer.x, bounds.minX, bounds.maxX), dy: axis(pointer.y, bounds.minY, bounds.maxY))
    }
}

public extension CanvasViewport {
    /// One auto-scroll step: pans by the pointer's `AutoScroll` velocity over `elapsed` seconds.
    /// Returns false when nothing moved (the pointer is away from the edges, the media is fitted,
    /// or it already shows its edge in that direction).
    mutating func autoScroll(pointer: CGPoint, elapsed: TimeInterval, view: CGSize, media: CGSize) -> Bool {
        let velocity = AutoScroll.velocity(pointer: pointer, in: CGRect(origin: .zero, size: view))
        guard velocity != .zero, elapsed > 0, let before = layout(view: view, media: media), before.canPan else { return false }
        pan(by: CGVector(dx: velocity.dx * elapsed, dy: velocity.dy * elapsed), view: view, media: media)
        guard let after = layout(view: view, media: media) else { return false }
        return abs(after.imageRect.minX - before.imageRect.minX) > 0.01 || abs(after.imageRect.minY - before.imageRect.minY) > 0.01
    }
}
