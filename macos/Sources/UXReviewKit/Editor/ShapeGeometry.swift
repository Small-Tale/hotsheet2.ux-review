import CoreGraphics
import Foundation

// Geometry for the annotation editor: converting between a media item's pixel space (where
// the editor's gestures happen) and the bundle's normalized 0…10000 space, hit testing, and
// moving / resizing shapes. Spec: docs/06-annotation-editor.md §6.3–6.4.

/// The pixel size of the media being edited. Gestures arrive in media pixels (top-left origin);
/// shapes are stored normalized.
public struct MediaFrame: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = max(width, 1)
        self.height = max(height, 1)
    }

    public init(_ item: MediaItem) {
        self.init(width: Double(item.pixelWidth), height: Double(item.pixelHeight))
    }

    public var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    private static let scale = Double(NormalizedSpace.max)

    public func pixel(_ point: NormPoint) -> CGPoint {
        CGPoint(x: Double(point.x) / Self.scale * width, y: Double(point.y) / Self.scale * height)
    }

    public func pixel(_ rect: NormRect) -> CGRect {
        CGRect(
            x: Double(rect.x) / Self.scale * width,
            y: Double(rect.y) / Self.scale * height,
            width: Double(rect.width) / Self.scale * width,
            height: Double(rect.height) / Self.scale * height
        )
    }

    /// The nearest normalized point, clamped to the media.
    public func norm(_ point: CGPoint) -> NormPoint {
        NormPoint(x: Self.unit(point.x / width), y: Self.unit(point.y / height))
    }

    /// The normalized rect covering `rect` after clamping it to the media, at least 1 unit on
    /// each side so it always validates.
    public func norm(_ rect: CGRect) -> NormRect {
        let clipped = rect.standardized.intersection(bounds)
        let source = clipped.isNull ? CGRect(origin: rect.origin, size: .zero) : clipped
        let x = min(Self.unit(source.minX / width), NormalizedSpace.max - 1)
        let y = min(Self.unit(source.minY / height), NormalizedSpace.max - 1)
        let maxX = Self.unit(source.maxX / width)
        let maxY = Self.unit(source.maxY / height)
        return NormRect(x: x, y: y, width: max(maxX - x, 1), height: max(maxY - y, 1))
    }

    private static func unit(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return min(max(Int((fraction * scale).rounded()), 0), NormalizedSpace.max)
    }
}

/// The eight resize handles of a box, clockwise from the top-left corner.
public enum BoxHandle: String, CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Where the handle sits on `rect`.
    public func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    var movesMinX: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var movesMaxX: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var movesMinY: Bool { [.topLeft, .top, .topRight].contains(self) }
    var movesMaxY: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
}

/// A grab point on the selected shape.
public enum ShapeHandle: Hashable, Sendable {
    /// A box handle: rect and strike resize; freehand scales its points.
    case box(BoxHandle)
    /// One vertex of an arrow path.
    case vertex(Int)
}

public extension Shape {
    /// The handles the selected shape offers, with their pixel positions.
    func handles(in frame: MediaFrame) -> [(handle: ShapeHandle, position: CGPoint)] {
        switch self {
        case let .rect(rect), let .strike(rect):
            let box = frame.pixel(rect)
            return BoxHandle.allCases.map { (.box($0), $0.position(in: box)) }
        case .freehand:
            let box = frame.pixel(bounds)
            return BoxHandle.allCases.map { (.box($0), $0.position(in: box)) }
        case let .arrow(points):
            return points.enumerated().map { (.vertex($0.offset), frame.pixel($0.element)) }
        case .insertion:
            return []
        }
    }

    /// Hit distance used to pick shapes: 0 inside a filled area, otherwise the distance in
    /// pixels to the nearest stroke. Nil when farther than `tolerance`.
    func hitDistance(_ point: CGPoint, in frame: MediaFrame, tolerance: Double) -> Double? {
        let distance: Double
        switch self {
        case let .rect(rect), let .strike(rect):
            distance = Geometry.distance(point, toRect: frame.pixel(rect))
        case let .freehand(points, closed):
            let pixels = points.map(frame.pixel)
            if closed, Geometry.contains(pixels, point) {
                distance = 0
            } else {
                distance = Geometry.distance(point, toPolyline: closed ? pixels + pixels.prefix(1) : pixels)
            }
        case let .arrow(points):
            distance = Geometry.distance(point, toPolyline: points.map(frame.pixel))
        case let .insertion(location):
            // The cursor glyph stands above its point and the caret hangs below; both count.
            let anchor = frame.pixel(location)
            let glyph = CGRect(x: anchor.x - tolerance, y: anchor.y - tolerance * 2.5, width: tolerance * 2, height: tolerance * 3.75)
            distance = Geometry.distance(point, toRect: glyph)
        }
        return distance <= tolerance ? distance : nil
    }

    /// The shape moved by a normalized offset, with the offset limited so it stays on the media.
    func translated(dx: Int, dy: Int) -> Shape {
        let points = allPoints
        let limit = NormalizedSpace.max
        let lowX = -(points.map(\.x).min() ?? 0), highX = limit - (points.map(\.x).max() ?? 0)
        let lowY = -(points.map(\.y).min() ?? 0), highY = limit - (points.map(\.y).max() ?? 0)
        let clampedX = min(max(dx, lowX), max(highX, lowX))
        let clampedY = min(max(dy, lowY), max(highY, lowY))
        return mapPoints { NormPoint(x: $0.x + clampedX, y: $0.y + clampedY) }
    }

    /// Every defining point (rect corners for boxes).
    internal var allPoints: [NormPoint] {
        switch self {
        case let .rect(rect), let .strike(rect):
            [NormPoint(x: rect.x, y: rect.y), NormPoint(x: rect.x + rect.width, y: rect.y + rect.height)]
        case let .freehand(points, _), let .arrow(points):
            points.isEmpty ? [NormPoint(x: 0, y: 0)] : points
        case let .insertion(point):
            [point]
        }
    }

    /// Applies `transform` to every defining point.
    internal func mapPoints(_ transform: (NormPoint) -> NormPoint) -> Shape {
        switch self {
        case let .rect(rect): .rect(Self.mapRect(rect, transform))
        case let .strike(rect): .strike(Self.mapRect(rect, transform))
        case let .freehand(points, closed): .freehand(points: points.map(transform), closed: closed)
        case let .arrow(points): .arrow(points: points.map(transform))
        case let .insertion(point): .insertion(transform(point))
        }
    }

    private static func mapRect(_ rect: NormRect, _ transform: (NormPoint) -> NormPoint) -> NormRect {
        let origin = transform(NormPoint(x: rect.x, y: rect.y))
        let end = transform(NormPoint(x: rect.x + rect.width, y: rect.y + rect.height))
        return NormRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
    }

    /// The shape after dragging `handle` to `point` (media pixels). Boxes keep at least
    /// `minimumSide` pixels and never flip past their opposite edge.
    func resized(_ handle: ShapeHandle, to point: CGPoint, in frame: MediaFrame, minimumSide: Double) -> Shape {
        let target = CGPoint(x: min(max(point.x, 0), frame.width), y: min(max(point.y, 0), frame.height))
        switch (self, handle) {
        case let (.rect(rect), .box(box)):
            return .rect(frame.norm(Self.resize(frame.pixel(rect), box, to: target, minimumSide: minimumSide, in: frame)))
        case let (.strike(rect), .box(box)):
            return .strike(frame.norm(Self.resize(frame.pixel(rect), box, to: target, minimumSide: minimumSide, in: frame)))
        case let (.freehand(points, closed), .box(box)):
            let old = frame.pixel(bounds)
            let new = Self.resize(old, box, to: target, minimumSide: minimumSide, in: frame)
            let scaled = points.map { norm -> NormPoint in
                let pixel = frame.pixel(norm)
                let fractionX = old.width > 0 ? (pixel.x - old.minX) / old.width : 0
                let fractionY = old.height > 0 ? (pixel.y - old.minY) / old.height : 0
                return frame.norm(CGPoint(x: new.minX + fractionX * new.width, y: new.minY + fractionY * new.height))
            }
            return .freehand(points: scaled, closed: closed)
        case let (.arrow(points), .vertex(index)) where points.indices.contains(index):
            var moved = points
            moved[index] = frame.norm(target)
            return .arrow(points: moved)
        default:
            return self
        }
    }

    private static func resize(
        _ rect: CGRect,
        _ handle: BoxHandle,
        to point: CGPoint,
        minimumSide: Double,
        in frame: MediaFrame
    ) -> CGRect {
        let side = min(minimumSide, frame.width, frame.height)
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesMinX { minX = min(point.x, maxX - side) }
        if handle.movesMaxX { maxX = max(point.x, minX + side) }
        if handle.movesMinY { minY = min(point.y, maxY - side) }
        if handle.movesMaxY { maxY = max(point.y, minY + side) }
        // Keep the minimum size inside the media when pushed against an edge.
        if maxX > frame.width { minX -= maxX - frame.width; maxX = frame.width }
        if maxY > frame.height { minY -= maxY - frame.height; maxY = frame.height }
        if minX < 0 { maxX -= minX; minX = 0 }
        if minY < 0 { maxY -= minY; minY = 0 }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Plane geometry helpers in pixel space.
enum Geometry {
    static func distance(_ point: CGPoint, toRect rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func distance(_ point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> Double {
        let segmentX = end.x - start.x, segmentY = end.y - start.y
        let lengthSquared = segmentX * segmentX + segmentY * segmentY
        let along = lengthSquared == 0 ? 0 : min(
            max(((point.x - start.x) * segmentX + (point.y - start.y) * segmentY) / lengthSquared, 0),
            1
        )
        let offsetX = start.x + along * segmentX - point.x, offsetY = start.y + along * segmentY - point.y
        return (offsetX * offsetX + offsetY * offsetY).squareRoot()
    }

    static func distance(_ point: CGPoint, toPolyline points: [CGPoint]) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        return zip(points, points.dropFirst()).map { distance(point, toSegment: $0, $1) }.min() ?? .infinity
    }

    /// Even-odd point-in-polygon test.
    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y),
               point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    /// Area of the bounding box, used to prefer the smallest of overlapping hits.
    static func area(_ rect: NormRect) -> Int { rect.width * rect.height }
}
