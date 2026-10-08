import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// HS2-JHTAZM: shapes that stick out of the (cropped) media are drawn clipped exactly to the
/// media, as they will be submitted, never into the canvas around it. Spec: docs/06 §6.6.
struct AnnotationClipTests {
    /// The canvas: 200 × 120 points of dark background with the media at (20, 10, 160 × 100).
    static let canvas = CGSize(width: 200, height: 120)
    static let imageRect = CGRect(x: 20, y: 10, width: 160, height: 100)
    /// The canvas gray (0.13, as in the editor), as stored in the sRGB bitmap.
    static let backgroundGray: CGFloat = 0.13

    /// Draws `shapes` like the editor canvas (flipped, media rect inset) and returns RGBA bytes.
    static func render(_ shapes: [Shape], lineWidth: CGFloat = 2.5) throws -> [UInt8] {
        let width = Int(canvas.width), height = Int(canvas.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: backgroundGray, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(imageRect)
        let renderer = AnnotationRenderer(frame: MediaFrame(width: 160, height: 100), imageRect: imageRect, lineWidth: lineWidth)
        let items = shapes.enumerated().map { index, shape in
            AnnotationRenderer.Item(number: index + 1, annotation: Annotation(id: "a\(index)", mediaId: "m", shape: shape, note: ""))
        }
        renderer.draw(items, in: context)
        return bytes
    }

    /// Whether the pixel at (`x`, `y`) (top-left origin, as drawn) is still the canvas background:
    /// the same bytes as the top-left corner, which nothing draws on.
    static func isBackground(_ bytes: [UInt8], _ x: Int, _ y: Int) -> Bool {
        let offset = (y * Int(canvas.width) + x) * 4
        return bytes[offset ..< offset + 4].elementsEqual(bytes[0 ..< 4])
    }

    /// Whether the pixel is neither background nor the white media: a stroke.
    static func isStroke(_ bytes: [UInt8], _ x: Int, _ y: Int) -> Bool {
        let offset = (y * Int(canvas.width) + x) * 4
        let pixel = bytes[offset ..< offset + 3]
        return !isBackground(bytes, x, y) && pixel.contains { $0 < 240 }
    }

    /// Where the badges of `shapes` are drawn (unclipped, outside each shape's top-left), padded.
    static func badgeArea(_ shapes: [Shape], lineWidth: CGFloat) -> CGRect {
        let renderer = AnnotationRenderer(frame: MediaFrame(width: 160, height: 100), imageRect: imageRect, lineWidth: lineWidth)
        return shapes.reduce(CGRect.null) { area, shape in
            let center = renderer.badgeCenter(for: shape)
            let radius = renderer.badgeRadius * 1.2 + 2
            return area.union(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    /// Every canvas pixel outside the media rect, except the badges' corner, is background.
    static func outsideIsUntouched(_ bytes: [UInt8], badgeArea: CGRect = .null) -> Bool {
        for y in 0 ..< Int(canvas.height) {
            for x in 0 ..< Int(canvas.width) {
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if imageRect.contains(point) || badgeArea.contains(point) { continue }
                if !isBackground(bytes, x, y) { return false }
            }
        }
        return true
    }

    /// The reported case: an arrow leaving the media on the right (its head well outside) is cut
    /// at the media's edge; the shaft inside is drawn right up to it.
    @Test func anArrowLeavingTheMediaStopsAtItsEdge() throws {
        let arrow = Shape.arrow(points: [NormPoint(x: 5000, y: 5000), NormPoint(x: 13000, y: 5000)])
        let bytes = try Self.render([arrow])
        let drawnOutside = (181 ..< 200).flatMap { x in (50 ..< 70).map { (x, $0) } }.filter { !Self.isBackground(bytes, $0.0, $0.1) }
        #expect(
            drawnOutside.isEmpty,
            "\(drawnOutside.count) pixels drawn right of the media, first \(String(describing: drawnOutside.first))"
        )
        #expect(Self.isStroke(bytes, 179, 60))
        #expect(Self.isStroke(bytes, 120, 60))
    }

    /// Every shape crossing every edge, at a thick stroke: nothing but the badges (which sit
    /// outside the shape's top-left on purpose) reaches the canvas around the media.
    @Test func everyShapeCrossingEveryEdgeIsClipped() throws {
        let shapes: [Shape] = [
            .rect(NormRect(x: -2000, y: -2000, width: 4000, height: 4000)), // top-left corner
            .rect(NormRect(x: 8000, y: 6000, width: 4000, height: 6000)), // right and bottom
            .arrow(points: [NormPoint(x: 5000, y: 5000), NormPoint(x: 5000, y: -3000)]), // up
            .arrow(points: [NormPoint(x: 5000, y: 5000), NormPoint(x: -3000, y: 9000)]), // down-left
            .freehand(points: [NormPoint(x: 9000, y: 2000), NormPoint(x: 12000, y: 3000), NormPoint(x: 9000, y: 4000)], closed: true),
            .strike(NormRect(x: 9000, y: 9000, width: 3000, height: 3000)),
        ]
        let bytes = try Self.render(shapes, lineWidth: 6)
        // Badges are drawn outside shapes' top-left corners, unclipped; leave out their corners.
        let badges = Self.badgeArea(shapes, lineWidth: 6)
        // The badge area must not cover the right and bottom margins we care most about.
        #expect(!badges.contains(CGPoint(x: 190, y: 115)))
        #expect(Self.outsideIsUntouched(bytes, badgeArea: badges))
        // And the shapes are drawn inside, right up to the edges they cross.
        #expect(Self.isStroke(bytes, 52, 20)) // the top-left rect's right side
        #expect(Self.isStroke(bytes, 35, 30)) // and its bottom side
        #expect(Self.isStroke(bytes, 148, 90)) // the bottom-right rect's left side
        #expect(Self.isStroke(bytes, 165, 70)) // and its top side
    }

    /// A rect exactly on the media's edges keeps the inner half of its stroke, as submitted.
    @Test func aFullFrameRectKeepsTheInnerHalfOfItsStroke() throws {
        let rect = Shape.rect(NormRect(x: 0, y: 0, width: 10000, height: 10000))
        let bytes = try Self.render([rect], lineWidth: 4)
        #expect(Self.outsideIsUntouched(bytes, badgeArea: Self.badgeArea([rect], lineWidth: 4)))
        #expect(Self.isStroke(bytes, 100, 10)) // top edge, inner half
        #expect(Self.isStroke(bytes, 179, 60)) // right edge, inner half
        #expect(Self.isStroke(bytes, 100, 109)) // bottom edge, inner half
    }
}
