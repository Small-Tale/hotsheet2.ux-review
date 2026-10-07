import CoreGraphics
import Foundation

/// An integer rectangle in image pixels (top-left origin).
public struct PixelRect: Codable, Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// `rect` snapped outward to whole pixels and clipped to `width`×`height`; nil when nothing
    /// of it is left.
    public static func snapping(_ rect: CGRect, width: Int, height: Int) -> PixelRect? {
        let standard = rect.standardized
        let minX = max(Int(standard.minX.rounded(.down)), 0)
        let minY = max(Int(standard.minY.rounded(.down)), 0)
        let maxX = min(Int(standard.maxX.rounded(.up)), width)
        let maxY = min(Int(standard.maxY.rounded(.up)), height)
        guard maxX > minX, maxY > minY else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Crop math: which part of the image survives, and where each annotation lands in the cropped
/// image. Spec: docs/06-annotation-editor.md §6.6.
public enum ImageCrop {
    /// Crops narrower or shorter than this many pixels are refused.
    public static let minimumSide = 8

    /// Maps a shape on the uncropped image (`frame`) into the crop. Returns nil when the shape
    /// falls entirely outside it; parts that stick out are clipped (boxes) or pulled to the
    /// crop's edge (points).
    public static func transform(_ shape: Shape, from frame: MediaFrame, crop: PixelRect) -> Shape? {
        let cropRect = crop.cgRect
        let target = MediaFrame(width: Double(crop.width), height: Double(crop.height))
        func moved(_ point: NormPoint) -> NormPoint {
            let pixel = frame.pixel(point)
            return target.norm(CGPoint(x: pixel.x - cropRect.minX, y: pixel.y - cropRect.minY))
        }
        func movedRect(_ rect: NormRect) -> NormRect? {
            let overlap = frame.pixel(rect).intersection(cropRect)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
            return target.norm(overlap.offsetBy(dx: -cropRect.minX, dy: -cropRect.minY))
        }
        switch shape {
        case let .rect(rect):
            return movedRect(rect).map(Shape.rect)
        case let .strike(rect):
            return movedRect(rect).map(Shape.strike)
        case let .insertion(point):
            return containsInclusive(cropRect, frame.pixel(point)) ? .insertion(moved(point)) : nil
        case let .freehand(points, closed):
            guard intersects(frame.pixel(shape.bounds), cropRect) else { return nil }
            return .freehand(points: points.map(moved), closed: closed)
        case let .arrow(points):
            guard intersects(frame.pixel(shape.bounds), cropRect) else { return nil }
            return .arrow(points: points.map(moved))
        }
    }

    /// `CGRect.contains` excludes the max edges; an insertion point exactly on them still counts.
    private static func containsInclusive(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    /// Bounding boxes of thin paths can have zero width or height, so touching counts.
    private static func intersects(_ box: CGRect, _ crop: CGRect) -> Bool {
        box.minX <= crop.maxX && box.maxX >= crop.minX && box.minY <= crop.maxY && box.maxY >= crop.minY
    }

    /// The cropped pixels of `image`.
    public static func apply(_ crop: PixelRect, to image: CGImage) -> CGImage? {
        image.cropping(to: crop.cgRect)
    }
}
