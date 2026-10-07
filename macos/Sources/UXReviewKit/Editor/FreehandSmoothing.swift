import CoreGraphics
import Foundation

/// Cleans up a freehand outline as drawn: removes pointer jitter and redundant samples while
/// staying faithful to the stroke. Nothing ever moves more than `tolerance` from where it was
/// drawn, and sharp corners are kept (no aggressive simplification that would round them off or
/// collapse them). Spec: docs/06-annotation-editor.md §6.3.
public enum FreehandSmoothing {
    /// A point turning more sharply than this (degrees) is a corner and never moves.
    public static let cornerAngle: Double = 55
    /// Neighbour-averaging passes.
    static let passes = 2

    /// `points` smoothed as an open stroke (endpoints exact) or a closed outline (wrapping). Points
    /// closer than `spacing` are merged first; then light averaging moves each remaining point by
    /// at most `tolerance`, corners excepted; finally near-collinear points (within `tolerance / 2`)
    /// are dropped. Inputs with fewer than 3 distinct points come back as they are.
    public static func smooth(_ points: [CGPoint], closed: Bool, spacing: Double, tolerance: Double) -> [CGPoint] {
        let sampled = resample(points, closed: closed, spacing: max(spacing, 0))
        guard sampled.count >= 3, tolerance > 0 else { return sampled }
        let averaged = average(sampled, closed: closed, tolerance: tolerance)
        let simplified = simplify(averaged, closed: closed, epsilon: tolerance / 2)
        return simplified.count >= 3 ? simplified : widest(averaged)
    }

    /// An (almost) straight stroke still needs 3 points to be an outline: its ends and the point
    /// farthest from the line between them.
    static func widest(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 3, let first = points.first, let last = points.last else { return points }
        let inner = 1 ..< points.count - 1
        let far = inner.max { segmentDistance(points[$0], first, last) < segmentDistance(points[$1], first, last) } ?? 1
        return [first, points[far], last]
    }

    // MARK: Steps

    /// Keeps a point once it is at least `spacing` from the last kept one. An open stroke keeps its
    /// last point (replacing a kept point too close to it); a closed outline drops a last point
    /// that has come back onto the first.
    static func resample(_ points: [CGPoint], closed: Bool, spacing: Double) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var kept = [first]
        for point in points.dropFirst() where distance(point, kept[kept.count - 1]) >= spacing && point != kept[kept.count - 1] {
            kept.append(point)
        }
        if closed {
            while kept.count > 1, distance(kept[kept.count - 1], first) < spacing {
                kept.removeLast()
            }
        } else if let last = points.last, last != kept[kept.count - 1] {
            if kept.count > 1, distance(last, kept[kept.count - 1]) < spacing { kept.removeLast() }
            kept.append(last)
        }
        return kept
    }

    /// [1, 2, 1] / 4 averaging, `passes` times, each point's total move clamped to `tolerance` from
    /// where it was drawn. Open endpoints and corners stay put.
    static func average(_ points: [CGPoint], closed: Bool, tolerance: Double) -> [CGPoint] {
        let count = points.count
        let pinned = (0 ..< count).map { index in
            (!closed && (index == 0 || index == count - 1)) || isCorner(points, at: index, closed: closed)
        }
        var current = points
        for _ in 0 ..< passes {
            var next = current
            for index in 0 ..< count where !pinned[index] {
                let previous = current[(index - 1 + count) % count]
                let following = current[(index + 1) % count]
                let target = CGPoint(
                    x: (previous.x + 2 * current[index].x + following.x) / 4,
                    y: (previous.y + 2 * current[index].y + following.y) / 4
                )
                next[index] = clamp(target, around: points[index], radius: tolerance)
            }
            current = next
        }
        return current
    }

    /// The turn at `index`, measured against the points two steps away on each side (adjacent
    /// samples are too jittery to judge), exceeds `cornerAngle`.
    static func isCorner(_ points: [CGPoint], at index: Int, closed: Bool) -> Bool {
        let count = points.count
        let reach = min(2, (count - 1) / 2)
        guard reach >= 1 else { return false }
        if !closed, index - reach < 0 || index + reach >= count { return false }
        let before = points[(index - reach + count) % count]
        let here = points[index]
        let after = points[(index + reach) % count]
        let incoming = CGVector(dx: here.x - before.x, dy: here.y - before.y)
        let outgoing = CGVector(dx: after.x - here.x, dy: after.y - here.y)
        let lengths = hypot(incoming.dx, incoming.dy) * hypot(outgoing.dx, outgoing.dy)
        guard lengths > 0 else { return false }
        let cosine = Double((incoming.dx * outgoing.dx + incoming.dy * outgoing.dy) / lengths)
        return Foundation.acos(min(max(cosine, -1), 1)) * 180 / .pi > cornerAngle
    }

    /// Douglas–Peucker with a small `epsilon`: drops points that lie (almost) on the line between
    /// their kept neighbours. A closed outline is split at its point farthest from the first.
    static func simplify(_ points: [CGPoint], closed: Bool, epsilon: Double) -> [CGPoint] {
        guard points.count > 3 else { return points }
        if closed {
            let far = points.indices.max { distance(points[$0], points[0]) < distance(points[$1], points[0]) } ?? 0
            guard far > 0 else { return points }
            let first = douglasPeucker(Array(points[0 ... far]), epsilon: epsilon)
            let second = douglasPeucker(Array(points[far...]) + [points[0]], epsilon: epsilon)
            return first + second.dropFirst().dropLast()
        }
        return douglasPeucker(points, epsilon: epsilon)
    }

    private static func douglasPeucker(_ points: [CGPoint], epsilon: Double) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var farthest = 0
        var farthestDistance = 0.0
        for index in 1 ..< points.count - 1 {
            let gap = segmentDistance(points[index], first, last)
            if gap > farthestDistance {
                farthest = index
                farthestDistance = gap
            }
        }
        guard farthestDistance > epsilon else { return [first, last] }
        let left = douglasPeucker(Array(points[0 ... farthest]), epsilon: epsilon)
        let right = douglasPeucker(Array(points[farthest...]), epsilon: epsilon)
        return left.dropLast() + right
    }

    // MARK: Geometry

    static func distance(_ one: CGPoint, _ other: CGPoint) -> Double { hypot(one.x - other.x, one.y - other.y) }

    /// Distance from `point` to the segment `start`–`end`.
    public static func segmentDistance(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return distance(point, start) }
        let along = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / length, 0), 1)
        return distance(point, CGPoint(x: start.x + along * dx, y: start.y + along * dy))
    }

    private static func clamp(_ point: CGPoint, around origin: CGPoint, radius: Double) -> CGPoint {
        let gap = distance(point, origin)
        guard gap > radius, gap > 0 else { return point }
        let scale = radius / gap
        return CGPoint(x: origin.x + (point.x - origin.x) * scale, y: origin.y + (point.y - origin.y) * scale)
    }
}
