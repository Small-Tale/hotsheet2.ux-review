import CoreGraphics
import Foundation

/// Arrow heads (`HS2-HQV9R8`): each end of an arrow drawn in its `ArrowHead` style.
/// Spec: docs/06-annotation-editor.md §6.2.
extension AnnotationRenderer {
    /// One end of an arrow: its head, its tip, and the point the line comes from.
    struct ArrowEnd {
        var head: ArrowHead
        var tip: CGPoint
        var from: CGPoint
    }

    /// Adds the arrow's line to `path`, stopping short of an open circle, and returns its two ends.
    func addArrow(_ points: [NormPoint], heads: ArrowHeads, width: CGFloat, to path: CGMutablePath) -> [ArrowEnd] {
        var mapped = points.map(point)
        var ends: [ArrowEnd] = []
        if mapped.count >= 2 {
            let last = mapped.count - 1
            ends = [
                ArrowEnd(head: heads.start, tip: mapped[0], from: mapped[1]),
                ArrowEnd(head: heads.end, tip: mapped[last], from: mapped[last - 1]),
            ]
            // The line stops at an open circle's edge instead of crossing it.
            mapped[0] = Self.inset(mapped[0], toward: mapped[1], by: Self.headInset(heads.start, width: width))
            mapped[last] = Self.inset(mapped[last], toward: mapped[last - 1], by: Self.headInset(heads.end, width: width))
        }
        path.addLines(between: mapped)
        return ends
    }

    /// One end of an arrow (`ArrowHead`, `HS2-HQV9R8`), sized to the line width and given the
    /// same dark halo as the line.
    func drawArrowHead(_ end: ArrowEnd, width: CGFloat, intent: Intent, in context: CGContext) {
        let tip = end.tip
        let angle = atan2(tip.y - end.from.y, tip.x - end.from.x)
        let length = width * 4 + 6
        let spread = CGFloat.pi / 7
        func back(_ turn: CGFloat, _ distance: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - distance * cos(angle + turn), y: tip.y - distance * sin(angle + turn))
        }
        let path = CGMutablePath()
        var filled = false
        switch end.head {
        case .none:
            return
        case .closed:
            path.move(to: tip)
            path.addLine(to: back(-spread, length))
            path.addLine(to: back(spread, length))
            path.closeSubpath()
            filled = true
        case .open:
            path.move(to: back(-spread, length))
            path.addLine(to: tip)
            path.addLine(to: back(spread, length))
        case .flat:
            let half = length * 0.55
            path.move(to: back(.pi / 2, half))
            path.addLine(to: back(-.pi / 2, half))
        case .openCircle, .closedCircle:
            let radius = Self.circleRadius(width: width)
            path.addEllipse(in: CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2))
            filled = end.head == .closedCircle
        }
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.45))
        context.setLineWidth(filled ? 2.5 : width + 2.5)
        context.strokePath()
        context.addPath(path)
        if filled {
            context.setFillColor(IntentPalette.color(intent))
            context.fillPath()
        } else {
            context.setStrokeColor(IntentPalette.color(intent))
            context.setLineWidth(width)
            context.strokePath()
        }
    }

    static func circleRadius(width: CGFloat) -> CGFloat {
        width * 1.6 + 3
    }

    /// How far the line stops short of its tip: an open circle's radius, so the line meets its edge.
    static func headInset(_ head: ArrowHead, width: CGFloat) -> CGFloat {
        head == .openCircle ? circleRadius(width: width) : 0
    }

    /// `point` moved `distance` toward `other`, never past it.
    static func inset(_ point: CGPoint, toward other: CGPoint, by distance: CGFloat) -> CGPoint {
        let length = hypot(other.x - point.x, other.y - point.y)
        guard distance > 0, length > 0 else { return point }
        let fraction = min(distance / length, 1)
        return CGPoint(x: point.x + (other.x - point.x) * fraction, y: point.y + (other.y - point.y) * fraction)
    }
}
