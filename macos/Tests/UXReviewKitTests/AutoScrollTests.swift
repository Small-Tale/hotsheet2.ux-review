import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// Auto-scroll near the canvas edges while a gesture runs (docs/06-annotation-editor.md §6.2.1):
/// the speed/direction rule, then long simulated drags over a zoomed 5K capture.
struct AutoScrollTests {
    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    static let view = bounds.size
    static let media = CGSize(width: 5120, height: 2880)

    static func velocity(_ x: CGFloat, _ y: CGFloat) -> CGVector { AutoScroll.velocity(pointer: CGPoint(x: x, y: y), in: bounds) }

    @Test func stillInTheMiddleAndUpToTheZone() {
        #expect(Self.velocity(400, 300) == .zero)
        #expect(Self.velocity(20, 300) == .zero, "exactly at the zone's inner edge")
        #expect(Self.velocity(780, 580) == .zero)
    }

    @Test func eachEdgeRevealsWhatLiesPastIt() {
        #expect(Self.velocity(5, 300).dx > 0 && Self.velocity(5, 300).dy == 0, "left edge: the media moves right")
        #expect(Self.velocity(795, 300).dx < 0, "right edge: the media moves left")
        #expect(Self.velocity(400, 5).dy > 0, "top edge: the media moves down")
        #expect(Self.velocity(400, 595).dy < 0, "bottom edge: the media moves up")
        let corner = Self.velocity(795, 595)
        #expect(corner.dx < 0 && corner.dy < 0, "corners scroll diagonally")
        #expect(abs(corner.dx) == abs(corner.dy))
    }

    @Test func speedGrowsWithDepthAndIsCapped() {
        let speeds = [790, 795, 800, 850, 900].map { abs(Self.velocity(CGFloat($0), 300).dx) }
        #expect(speeds == speeds.sorted() && Set(speeds).count == speeds.count, "proportional to depth: \(speeds)")
        let depth: CGFloat = 10
        #expect(abs(
            abs(Self.velocity(800 - AutoScroll.edgeZone + depth, 300).dx)
                - depth / (AutoScroll.edgeZone + AutoScroll.ramp) * AutoScroll.maxSpeed
        ) < 0.001)
        #expect(abs(Self.velocity(5000, 300).dx) == AutoScroll.maxSpeed, "far outside: capped")
        #expect(abs(Self.velocity(-5000, 300).dx) == AutoScroll.maxSpeed)
    }

    @Test func aTinyCanvasNeverScrolls() {
        #expect(AutoScroll.velocity(pointer: CGPoint(x: 1, y: 1), in: CGRect(x: 0, y: 0, width: 30, height: 30)) == .zero)
    }

    /// 400 % of a 5K capture on a 2× screen: 2 points per pixel.
    static func zoomed() -> CanvasViewport {
        var viewport = CanvasViewport()
        viewport.zoom(to: 2, anchor: nil, view: view, media: media, backingScale: 2)
        return viewport
    }

    /// The media pixel under `pointer`.
    static func pixel(_ viewport: CanvasViewport, _ pointer: CGPoint) throws -> CGPoint {
        let layout = try #require(viewport.layout(view: view, media: media))
        return CGPoint(x: (pointer.x - layout.imageRect.minX) / layout.scale, y: (pointer.y - layout.imageRect.minY) / layout.scale)
    }

    @Test func aHeldPointerScrollsSteadilyToTheMediaEdgeThenStops() throws {
        var viewport = Self.zoomed()
        let pointer = CGPoint(x: 795, y: 300) // held still near the right edge
        var seen = try [Self.pixel(viewport, pointer).x]
        var ticks = 0
        while viewport.autoScroll(pointer: pointer, elapsed: 1.0 / 60, view: Self.view, media: Self.media) {
            seen.append(try Self.pixel(viewport, pointer).x)
            ticks += 1
            #expect(ticks < 10000, "never stops")
            if ticks >= 10000 { break }
        }
        #expect(seen == seen.sorted() && seen.count > 10, "the media point under the pointer advances monotonically")
        let layout = try #require(viewport.layout(view: Self.view, media: Self.media))
        #expect(abs(layout.imageRect.maxX - (Self.view.width - CanvasViewport.padding)) < 0.5, "stops with the media's right edge shown")
        let moved1 = viewport.autoScroll(pointer: pointer, elapsed: 1.0 / 60, view: Self.view, media: Self.media)
        #expect(!moved1, "idle at the edge")
        let moved2 = viewport.autoScroll(pointer: CGPoint(x: 5, y: 300), elapsed: 1.0 / 60, view: Self.view, media: Self.media)
        #expect(
            moved2,
            "back the other way responds at once"
        )
    }

    @Test func distanceFollowsSpeedTimesTime() throws {
        var viewport = Self.zoomed()
        let pointer = CGPoint(x: 400, y: 590)
        let before = try Self.pixel(viewport, pointer)
        let moved3 = viewport.autoScroll(pointer: pointer, elapsed: 0.5, view: Self.view, media: Self.media)
        #expect(moved3)
        let after = try Self.pixel(viewport, pointer)
        let expected = abs(Self.velocity(400, 590).dy) * 0.5 / 2 // points → pixels at 2 points per pixel
        #expect(abs((after.y - before.y) - expected) < 0.01)
        #expect(after.x == before.x, "only the vertical edge scrolls")
    }

    @Test func fittedMediaAndTheMiddleNeverMove() {
        var fitted = CanvasViewport()
        let moved4 = fitted.autoScroll(pointer: CGPoint(x: 795, y: 595), elapsed: 1, view: Self.view, media: Self.media)
        #expect(!moved4)
        #expect(fitted == CanvasViewport())
        var zoomed = Self.zoomed()
        let before = zoomed
        let moved5 = zoomed.autoScroll(pointer: CGPoint(x: 400, y: 300), elapsed: 1, view: Self.view, media: Self.media)
        #expect(!moved5)
        let moved6 = zoomed.autoScroll(pointer: CGPoint(x: 795, y: 300), elapsed: 0, view: Self.view, media: Self.media)
        #expect(!moved6)
        #expect(zoomed == before)
    }

    /// A long drag drawn through the editor: the pointer parks at the right edge while the canvas
    /// scrolls, and the rectangle keeps growing with it (what the canvas timer does each tick).
    @Test func aLongDrawThroughTheEditorGrowsWithTheScroll() throws {
        let item = MediaItem(
            id: "m1", filename: "big.png", kind: .image, pixelWidth: 5120, pixelHeight: 2880, capturedAt: Date(timeIntervalSince1970: 0)
        )
        var editor = AnnotationEditor(bundle: TestSupport.bundle(media: [item], annotations: []))
        var viewport = Self.zoomed()
        editor.setTool(.rect)
        let start = CGPoint(x: 300, y: 200)
        editor.beginGesture(at: try Self.pixel(viewport, start))
        let pointer = CGPoint(x: 799, y: 420)
        editor.updateGesture(to: try Self.pixel(viewport, pointer))
        for _ in 0 ..< 120 where viewport.autoScroll(pointer: pointer, elapsed: 1.0 / 60, view: Self.view, media: Self.media) {
            editor.updateGesture(to: try Self.pixel(viewport, pointer))
        }
        editor.endGesture()
        let shape = try #require(editor.bundle.annotations.first?.shape)
        guard case let .rect(rect) = shape else { Issue.record("not a rect: \(shape)"); return }
        // Without scrolling it would end under the pointer: 499 pt / 2 pt per px ≈ 250 px. Two
        // seconds parked 19 pt into the zone add speed × 2 s / 2 pt per px.
        let widthPixels = Double(rect.width) / Double(NormalizedSpace.max) * 5120
        let scrolled = Double(abs(AutoScroll.velocity(pointer: pointer, in: Self.bounds).dx)) * 2 / 2
        #expect(abs(widthPixels - (249.5 + scrolled)) < 3, "the rectangle grew with the scroll: \(widthPixels) px")
    }
}
