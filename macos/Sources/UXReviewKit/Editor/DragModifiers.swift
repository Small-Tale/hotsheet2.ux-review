import CoreGraphics
import Foundation

/// The modifier keys held during a canvas drag (`HS2-Q5TA4C`), with the effects they have in other
/// Mac drawing apps. The canvas sets them on every drag event and when they change mid-drag, so
/// pressing or releasing a key reshapes the drag at once. Spec: docs/06-annotation-editor.md §6.3.
public struct DragModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// ⇧: resizing keeps the aspect ratio; a new rectangle, strike, or crop is a square; an arrow
    /// end snaps to the nearest 45°; moving a shape stays horizontal or vertical.
    public static let constrain = DragModifiers(rawValue: 1)
    /// ⌥: resizing and drawing are symmetric about the center (the opposite side moves too, and a
    /// new box grows from where the drag began).
    public static let fromCenter = DragModifiers(rawValue: 2)
}

/// The drag's modifier keys, where it began, and where the pointer is now (media pixels), so a
/// modifier change mid-drag can redo the last update (`AnnotationEditor.drag`).
struct DragState: Sendable {
    var modifiers: DragModifiers = []
    var anchor: CGPoint?
    var point: CGPoint?
}

public extension AnnotationEditor {
    /// The modifier keys held during the drag (⇧ constrain, ⌥ from center, `HS2-Q5TA4C`). Set
    /// them with `setDragModifiers`, which reshapes a drag in progress at once.
    var dragModifiers: DragModifiers { drag.modifiers }
}

/// Where a resized box must stay: inside `bounds` (the media, origin at 0, 0), at least
/// `minimumSide` on each side.
public struct BoxLimits: Equatable, Sendable {
    public var bounds: CGSize
    public var minimumSide: Double

    public init(bounds: CGSize, minimumSide: Double) {
        self.bounds = bounds
        self.minimumSide = minimumSide
    }
}

/// Box geometry under `DragModifiers`, in pixels, inside `bounds` (the media, origin at 0, 0).
public enum ModifiedBox {
    /// `rect` resized by dragging `handle` to `point`. With no modifiers, the plain resize
    /// (`Shape.resize`): the handle's edges follow the point. ⌥ moves the opposite edges by the same
    /// amount, about the center. ⇧ keeps `rect`'s aspect ratio: a corner scales both sides by the
    /// larger change; an edge scales the other side to match, centered on it. The box stays at least
    /// `minimumSide` and inside `bounds`, shrinking about its fixed point instead of sliding.
    public static func resize(
        _ rect: CGRect,
        _ handle: BoxHandle,
        to point: CGPoint,
        modifiers: DragModifiers,
        within limits: BoxLimits
    ) -> CGRect {
        let bounds = limits.bounds, minimumSide = limits.minimumSide
        let frame = MediaFrame(width: bounds.width, height: bounds.height)
        guard !modifiers.isEmpty else { return Shape.resize(rect, handle, to: point, minimumSide: minimumSide, in: frame) }
        let side = min(minimumSide, bounds.width, bounds.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let fromCenter = modifiers.contains(.fromCenter)
        let movesX = handle.movesMinX || handle.movesMaxX, movesY = handle.movesMinY || handle.movesMaxY
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if movesX {
            if fromCenter {
                let half = max(abs(point.x - center.x), side / 2)
                (minX, maxX) = (center.x - half, center.x + half)
            } else if handle.movesMinX {
                minX = min(point.x, maxX - side)
            } else {
                maxX = max(point.x, minX + side)
            }
        }
        if movesY {
            if fromCenter {
                let half = max(abs(point.y - center.y), side / 2)
                (minY, maxY) = (center.y - half, center.y + half)
            } else if handle.movesMinY {
                minY = min(point.y, maxY - side)
            } else {
                maxY = max(point.y, minY + side)
            }
        }
        // The point the box grows from: the center with ⌥, else the opposite edge (or, along an
        // axis the handle doesn't move, the middle, so an edge keeps the box centered there).
        let anchor = CGPoint(
            x: fromCenter || !movesX ? center.x : (handle.movesMinX ? rect.maxX : rect.minX),
            y: fromCenter || !movesY ? center.y : (handle.movesMinY ? rect.maxY : rect.minY)
        )
        var width = maxX - minX, height = maxY - minY
        let constrain = modifiers.contains(.constrain) && rect.width > 0 && rect.height > 0
        if constrain {
            let aspect = rect.width / rect.height
            if movesX, movesY {
                let scale = max(width / rect.width, height / rect.height)
                (width, height) = (rect.width * scale, rect.height * scale)
            } else if movesX {
                height = width / aspect
            } else {
                width = height * aspect
            }
            let grow = max(side / width, side / height, 1)
            (width, height) = (width * grow, height * grow)
        }
        guard constrain else {
            // ⌥ alone: the edges as moved above, kept inside the bounds about the center.
            return fit(CGRect(x: minX, y: minY, width: width, height: height), anchor: anchor, bounds: bounds, uniform: false)
        }
        // ⇧: the scaled box laid out around the anchor (the share of each side before it).
        let leftShare = anchorShare(fromCenter || !movesX, minEdgeMoves: handle.movesMinX)
        let topShare = anchorShare(fromCenter || !movesY, minEdgeMoves: handle.movesMinY)
        let box = CGRect(x: anchor.x - width * leftShare, y: anchor.y - height * topShare, width: width, height: height)
        return fit(box, anchor: anchor, bounds: bounds, uniform: true)
    }

    /// The box a new rectangle, strike, or crop covers while dragging from `anchor` to `point`:
    /// ⇧ makes it a square (the larger side), ⌥ centers it on `anchor`. It stays inside `bounds`.
    public static func drawn(from anchor: CGPoint, to point: CGPoint, modifiers: DragModifiers, bounds: CGSize) -> CGRect {
        var dx = point.x - anchor.x, dy = point.y - anchor.y
        let fromCenter = modifiers.contains(.fromCenter)
        // The room on the side the drag goes, from the anchor.
        let roomX = fromCenter ? min(anchor.x, bounds.width - anchor.x) : (dx < 0 ? anchor.x : bounds.width - anchor.x)
        let roomY = fromCenter ? min(anchor.y, bounds.height - anchor.y) : (dy < 0 ? anchor.y : bounds.height - anchor.y)
        if modifiers.contains(.constrain) {
            let length = min(max(abs(dx), abs(dy)), roomX, roomY)
            dx = (dx < 0 ? -1 : 1) * length
            dy = (dy < 0 ? -1 : 1) * length
        } else {
            dx = (dx < 0 ? -1 : 1) * min(abs(dx), roomX)
            dy = (dy < 0 ? -1 : 1) * min(abs(dy), roomY)
        }
        if fromCenter {
            return CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return CGRect(x: anchor.x, y: anchor.y, width: dx, height: dy).standardized
    }

    /// `point` moved onto the nearest 45° line through `anchor`, at the same distance along it, and
    /// pulled back inside `bounds` along that line.
    public static func snapped(_ point: CGPoint, from anchor: CGPoint, bounds: CGSize) -> CGPoint {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return point }
        let step = Double.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        let unit = CGPoint(x: cos(angle).rounded(toPlaces: 12), y: sin(angle).rounded(toPlaces: 12))
        var reach = length
        if unit.x > 0 { reach = min(reach, (bounds.width - anchor.x) / unit.x) }
        if unit.x < 0 { reach = min(reach, -anchor.x / unit.x) }
        if unit.y > 0 { reach = min(reach, (bounds.height - anchor.y) / unit.y) }
        if unit.y < 0 { reach = min(reach, -anchor.y / unit.y) }
        return CGPoint(x: anchor.x + unit.x * reach, y: anchor.y + unit.y * reach)
    }

    /// The share of a side that lies before the anchor: half when centered on it, all when the
    /// moving edge is the min edge (the anchor is the max edge), none otherwise.
    private static func anchorShare(_ centered: Bool, minEdgeMoves: Bool) -> Double {
        centered ? 0.5 : (minEdgeMoves ? 1 : 0)
    }

    /// `box` shrunk about `anchor` until it fits `bounds`: both sides by one factor when `uniform`
    /// (keeping the aspect ratio), else each axis on its own.
    private static func fit(_ box: CGRect, anchor: CGPoint, bounds: CGSize, uniform: Bool) -> CGRect {
        func factor(before: Double, after: Double, room: (before: Double, after: Double)) -> Double {
            var factor = 1.0
            if before > room.before, before > 0 { factor = min(factor, max(room.before, 0) / before) }
            if after > room.after, after > 0 { factor = min(factor, max(room.after, 0) / after) }
            return factor
        }
        let left = anchor.x - box.minX, right = box.maxX - anchor.x
        let top = anchor.y - box.minY, bottom = box.maxY - anchor.y
        var factorX = factor(before: left, after: right, room: (anchor.x, bounds.width - anchor.x))
        var factorY = factor(before: top, after: bottom, room: (anchor.y, bounds.height - anchor.y))
        if uniform { (factorX, factorY) = (min(factorX, factorY), min(factorX, factorY)) }
        return CGRect(
            x: anchor.x - left * factorX, y: anchor.y - top * factorY,
            width: (left + right) * factorX, height: (top + bottom) * factorY
        )
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
