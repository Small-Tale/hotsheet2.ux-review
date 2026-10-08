import CoreGraphics
import CoreText
import Foundation

public extension Annotation {
    /// The intent that colors the annotation: the first one the reviewer added beyond the shape's
    /// default (so a rect marked `comment, bug` reads as a bug), else the default.
    var primaryIntent: Intent {
        effectiveIntents.first { $0 != shape.defaultIntent } ?? shape.defaultIntent
    }
}

/// Colors for intents. A shape and its badge take the color of its `primaryIntent`.
public enum IntentPalette {
    /// sRGB components, picked to stay distinct from each other and readable on a dark halo.
    public static func rgb(_ intent: Intent) -> (red: Double, green: Double, blue: Double) {
        switch intent {
        case .comment: (0.04, 0.52, 1.00) // blue
        case .bug: (1.00, 0.27, 0.23) // red
        case .change: (1.00, 0.62, 0.04) // orange
        case .insert: (0.20, 0.78, 0.35) // green
        case .remove: (0.75, 0.35, 0.95) // purple
        case .move: (0.25, 0.78, 0.88) // teal
        case .question: (1.00, 0.84, 0.04) // yellow
        }
    }

    public static func color(_ intent: Intent, alpha: Double = 1) -> CGColor {
        let rgb = rgb(intent)
        return CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    /// Light intents get dark badge text.
    public static func usesDarkText(_ intent: Intent) -> Bool { intent == .question || intent == .move }
}

/// Draws annotations, numbered badges, selection handles, drawing previews, and the crop
/// overlay. The editor canvas, the offscreen UI previews, and `--annotate --render-dir` all use
/// it, so what the reviewer sees is what tests inspect. Spec: docs/06-annotation-editor.md §6.2.
public struct AnnotationRenderer {
    public struct Item {
        public var number: Int
        public var annotation: Annotation

        public init(number: Int, annotation: Annotation) {
            self.number = number
            self.annotation = annotation
        }
    }

    /// The media's pixel size.
    public var frame: MediaFrame
    /// Where the media is drawn, in the context's (top-left origin) coordinates.
    public var imageRect: CGRect
    /// Stroke width in context units.
    public var lineWidth: CGFloat = 2.5

    public init(frame: MediaFrame, imageRect: CGRect, lineWidth: CGFloat = 2.5) {
        self.frame = frame
        self.imageRect = imageRect
        self.lineWidth = lineWidth
    }

    /// Context units per media pixel.
    public var scale: CGFloat { imageRect.width / frame.width }

    public func point(_ pixel: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + pixel.x * scale, y: imageRect.minY + pixel.y * scale)
    }

    public func point(_ norm: NormPoint) -> CGPoint { point(frame.pixel(norm)) }

    public func rect(_ pixels: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + pixels.minX * scale,
            y: imageRect.minY + pixels.minY * scale,
            width: pixels.width * scale,
            height: pixels.height * scale
        )
    }

    /// The inverse of `point(_:)`: a context point in media pixels.
    public func pixel(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - imageRect.minX) / scale, y: (point.y - imageRect.minY) / scale)
    }

    /// Draws everything. `context` must use a top-left origin (flipped, as in an `NSView` with
    /// `isFlipped`).
    public func draw(
        _ items: [Item],
        selection: String? = nil,
        preview: Shape? = nil,
        crop: CGRect? = nil,
        in context: CGContext
    ) {
        // Shapes that stick out of a crop are drawn clipped to the image, as they will be
        // submitted (HS2-71SSJG); a stroke's width of slack keeps edge strokes whole.
        context.saveGState()
        context.clip(to: imageRect.insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2))
        for item in items {
            drawShape(item.annotation.shape, intent: item.annotation.primaryIntent, selected: item.annotation.id == selection, in: context)
        }
        context.restoreGState()
        if let preview {
            drawShape(preview, intent: preview.defaultIntent, selected: false, in: context)
        }
        for item in items {
            drawBadge(item, selected: item.annotation.id == selection, in: context)
        }
        if let selected = items.first(where: { $0.annotation.id == selection }) {
            drawHandles(selected.annotation.shape, in: context)
        }
        if let crop {
            drawCropOverlay(crop, in: context)
        }
    }

    // MARK: Shapes

    func drawShape(_ shape: Shape, intent: Intent, selected: Bool, in context: CGContext) {
        let path = CGMutablePath()
        var fill: CGFloat = 0
        var arrowHead: (tip: CGPoint, from: CGPoint)?
        switch shape {
        case let .rect(rect):
            path.addRect(self.rect(frame.pixel(rect)))
            fill = 0.08
        case let .strike(rect):
            let box = self.rect(frame.pixel(rect))
            path.addRect(box)
            path.move(to: CGPoint(x: box.minX, y: box.minY))
            path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
            path.move(to: CGPoint(x: box.maxX, y: box.minY))
            path.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        case let .freehand(points, closed):
            path.addLines(between: points.map(point))
            if closed {
                path.closeSubpath()
                fill = 0.12
            }
        case let .arrow(points):
            let mapped = points.map(point)
            path.addLines(between: mapped)
            if mapped.count >= 2 { arrowHead = (mapped[mapped.count - 1], mapped[mapped.count - 2]) }
        case let .insertion(location):
            // A text cursor (I-beam) standing on the point, with a proofreading caret just below.
            let anchor = point(location)
            let size = max(lineWidth * 3.5, 9)
            let serif = size * 0.35
            path.move(to: CGPoint(x: anchor.x, y: anchor.y))
            path.addLine(to: CGPoint(x: anchor.x, y: anchor.y - size * 1.8))
            for y in [anchor.y, anchor.y - size * 1.8] {
                path.move(to: CGPoint(x: anchor.x - serif, y: y))
                path.addLine(to: CGPoint(x: anchor.x + serif, y: y))
            }
            let apex = CGPoint(x: anchor.x, y: anchor.y + size * 0.35)
            path.move(to: CGPoint(x: apex.x - size * 0.7, y: apex.y + size * 0.8))
            path.addLine(to: apex)
            path.addLine(to: CGPoint(x: apex.x + size * 0.7, y: apex.y + size * 0.8))
        }
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if fill > 0 {
            context.addPath(path)
            context.setFillColor(IntentPalette.color(intent, alpha: selected ? fill * 1.6 : fill))
            context.fillPath(using: .evenOdd)
        }
        // A dark halo keeps every color readable on light and dark screenshots alike.
        let width = selected ? lineWidth * 1.4 : lineWidth
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.45))
        context.setLineWidth(width + 2.5)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(IntentPalette.color(intent))
        context.setLineWidth(width)
        context.strokePath()
        if let arrowHead {
            drawArrowHead(tip: arrowHead.tip, from: arrowHead.from, width: width, intent: intent, in: context)
        }
        context.restoreGState()
    }

    private func drawArrowHead(tip: CGPoint, from: CGPoint, width: CGFloat, intent: Intent, in context: CGContext) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let length = width * 4 + 6
        let spread = CGFloat.pi / 7
        let head = CGMutablePath()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)))
        head.addLine(to: CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread)))
        head.closeSubpath()
        context.addPath(head)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.45))
        context.setLineWidth(2.5)
        context.strokePath()
        context.addPath(head)
        context.setFillColor(IntentPalette.color(intent))
        context.fillPath()
    }

    // MARK: Badges and handles

    /// Where an annotation's number badge is centered: diagonally outside the shape's top-left
    /// corner, clear of the corner's resize handle (an arrow's tail, beside an insertion
    /// cursor), kept on the image.
    public func badgeCenter(for shape: Shape) -> CGPoint {
        let radius = badgeRadius
        let anchor: CGPoint
        switch shape {
        case let .arrow(points) where !points.isEmpty:
            let tail = point(points[0])
            anchor = CGPoint(x: tail.x - radius - 3, y: tail.y - radius - 3)
        case let .insertion(location):
            let caret = point(location)
            anchor = CGPoint(x: caret.x + radius * 1.4, y: caret.y - radius * 1.9)
        default:
            let box = rect(frame.pixel(shape.bounds))
            anchor = CGPoint(x: box.minX - radius - 2, y: box.minY - radius - 2)
        }
        let inset = imageRect.insetBy(dx: radius, dy: radius)
        guard inset.width > 0, inset.height > 0 else { return anchor }
        return CGPoint(x: min(max(anchor.x, inset.minX), inset.maxX), y: min(max(anchor.y, inset.minY), inset.maxY))
    }

    public var badgeRadius: CGFloat { max(lineWidth * 4, 10) }

    func drawBadge(_ item: Item, selected: Bool, in context: CGContext) {
        let intent = item.annotation.primaryIntent
        let center = badgeCenter(for: item.annotation.shape)
        let radius = badgeRadius * (selected ? 1.15 : 1)
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.5))
        context.setFillColor(IntentPalette.color(intent))
        context.fillEllipse(in: circle)
        context.restoreGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(selected ? 2.5 : 1.5)
        context.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))
        let textColor = IntentPalette.usesDarkText(intent) ? CGColor(gray: 0.1, alpha: 1) : CGColor(gray: 1, alpha: 1)
        Self.drawText("\(item.number)", centeredAt: center, size: radius * 1.05, color: textColor, in: context)
    }

    func drawHandles(_ shape: Shape, in context: CGContext) {
        let size: CGFloat = 9
        if case .freehand = shape {
            context.saveGState()
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(rect(frame.pixel(shape.bounds)))
            context.restoreGState()
        }
        // On small boxes the edge-midpoint handles would hide the shape; the corners suffice.
        let box = rect(frame.pixel(shape.bounds))
        let compact = min(box.width, box.height) < 36
        for (handle, position) in shape.handles(in: frame) {
            if compact, case let .box(boxHandle) = handle, [.top, .right, .bottom, .left].contains(boxHandle) { continue }
            let center = point(position)
            let box = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.setStrokeColor(CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1))
            context.setLineWidth(1.5)
            if case .vertex = handle {
                context.fillEllipse(in: box)
                context.strokeEllipse(in: box)
            } else {
                context.fill(box)
                context.stroke(box)
            }
        }
    }

    // MARK: Crop overlay

    func drawCropOverlay(_ crop: CGRect, in context: CGContext) {
        let box = rect(crop)
        context.saveGState()
        context.addRect(imageRect)
        context.addRect(box)
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.stroke(box)
        context.restoreGState()
        let label = "\(Int(crop.width.rounded())) × \(Int(crop.height.rounded())) px"
        let labelY = box.maxY + 16 < imageRect.maxY ? box.maxY + 12 : box.maxY - 12
        Self.drawText(
            label,
            centeredAt: CGPoint(x: box.midX, y: labelY),
            size: 12,
            color: CGColor(gray: 1, alpha: 1),
            background: CGColor(gray: 0, alpha: 0.7),
            in: context
        )
    }

    // MARK: Text

    /// Draws `text` centered at `center` in a flipped context.
    static func drawText(
        _ text: String,
        centeredAt center: CGPoint,
        size: CGFloat,
        color: CGColor,
        background: CGColor? = nil,
        in context: CGContext
    ) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        if let background {
            let pad: CGFloat = 4
            let box = CGRect(
                x: center.x - width / 2 - pad, y: center.y - (ascent + descent) / 2 - pad / 2,
                width: width + pad * 2, height: ascent + descent + pad
            )
            context.setFillColor(background)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
        }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: center.x - width / 2, y: center.y + (ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: Offscreen

    /// `image` with its annotations drawn on top at the image's pixel size. Stroke and badge
    /// sizes scale with the image so they stay readable whatever the capture's size.
    public static func render(
        image: CGImage,
        items: [Item],
        selection: String? = nil,
        lineWidth: CGFloat? = nil
    ) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let renderer = AnnotationRenderer(
            frame: MediaFrame(width: Double(width), height: Double(height)),
            imageRect: bounds,
            lineWidth: lineWidth ?? max(CGFloat(min(width, height)) / 300, 2.5)
        )
        renderer.draw(items, selection: selection, in: context)
        return context.makeImage()
    }
}
