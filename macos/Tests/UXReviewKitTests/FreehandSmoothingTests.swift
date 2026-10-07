import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// Freehand smoothing (docs/06-annotation-editor.md §6.3), as properties checked over many
/// seeded jittered strokes: bounded deviation both ways, point-count bounds, exact open
/// endpoints, kept corners, less jitter, and degenerate inputs.
struct FreehandSmoothingTests {
    static let spacing = 3.0
    static let tolerance = 1.5

    /// A small deterministic generator, so failures reproduce.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    static func jitter(_ points: [CGPoint], amount: Double, seed: UInt64) -> [CGPoint] {
        var random = Seeded(state: seed)
        return points.map { CGPoint(
            x: $0.x + .random(in: -amount ... amount, using: &random),
            y: $0.y + .random(in: -amount ... amount, using: &random)
        ) }
    }

    /// Samples every `step` along a polyline through `corners`.
    static func trace(_ corners: [CGPoint], step: Double = 1) -> [CGPoint] {
        var points: [CGPoint] = []
        for (start, end) in zip(corners, corners.dropFirst()) {
            let count = max(Int(FreehandSmoothing.distance(start, end) / step), 1)
            for index in 0 ..< count {
                let along = Double(index) / Double(count)
                points.append(CGPoint(x: start.x + (end.x - start.x) * along, y: start.y + (end.y - start.y) * along))
            }
        }
        return points + [corners[corners.count - 1]]
    }

    static func circle(radius: Double, count: Int) -> [CGPoint] {
        (0 ..< count).map { index in
            let angle = Double(index) / Double(count) * 2 * .pi
            return CGPoint(x: 200 + radius * cos(angle), y: 200 + radius * sin(angle))
        }
    }

    /// The largest distance from any of `points` to the polyline `path` (closing it if `closed`).
    static func deviation(of points: [CGPoint], from path: [CGPoint], closed: Bool) -> Double {
        let segments = Array(zip(path, path.dropFirst())) + (closed ? [(path[path.count - 1], path[0])] : [])
        return points.map { point in
            segments.map { FreehandSmoothing.segmentDistance(point, $0.0, $0.1) }.min() ?? 0
        }.max() ?? 0
    }

    static func smooth(_ points: [CGPoint], closed: Bool = false) -> [CGPoint] {
        FreehandSmoothing.smooth(points, closed: closed, spacing: spacing, tolerance: tolerance)
    }

    @Test(arguments: 0 ..< 40)
    func staysFaithfulBothWaysAndNeverGrows(seed: Int) {
        let shapes: [(points: [CGPoint], closed: Bool)] = [
            (Self.trace([CGPoint(x: 10, y: 10), CGPoint(x: 300, y: 40), CGPoint(x: 120, y: 260)]), false),
            (Self.circle(radius: 90, count: 400), true),
            (
                Self.trace([
                    CGPoint(x: 0, y: 0),
                    CGPoint(x: 200, y: 0),
                    CGPoint(x: 200, y: 120),
                    CGPoint(x: 0, y: 120),
                    CGPoint(x: 0, y: 0),
                ]),
                true
            ),
        ]
        for (index, shape) in shapes.enumerated() {
            let input = Self.jitter(shape.points, amount: 1.2, seed: UInt64(seed * 7 + index + 1))
            let output = Self.smooth(input, closed: shape.closed)
            #expect(output.count >= 3 && output.count <= input.count, "shape \(index): \(output.count) of \(input.count)")
            // Every output point lies within the tolerance (plus the resampling gap) of the stroke…
            let outward = Self.deviation(of: output, from: input, closed: shape.closed)
            #expect(outward <= Self.tolerance + 1e-9, "shape \(index) seed \(seed): output strays \(outward)")
            // …and the stroke stays within reach of the outline (no collapsed parts).
            let inward = Self.deviation(of: input, from: output, closed: shape.closed)
            #expect(inward <= Self.spacing + 2 * Self.tolerance, "shape \(index) seed \(seed): stroke lost by \(inward)")
        }
    }

    @Test func openStrokesKeepTheirEndpointsExactly() {
        let input = Self.jitter(Self.trace([CGPoint(x: 5, y: 5), CGPoint(x: 150, y: 90)]), amount: 1, seed: 3)
        let output = Self.smooth(input)
        #expect(output.first == input.first)
        #expect(output.last == input.last)
    }

    @Test func closedOutlinesDoNotRepeatTheirStart() {
        var input = Self.circle(radius: 50, count: 200)
        input.append(input[0])
        let output = Self.smooth(input, closed: true)
        #expect(FreehandSmoothing.distance(output[output.count - 1], output[0]) >= Self.spacing - 1e-9)
    }

    @Test func cornersStaySharp() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 120), CGPoint(x: 0, y: 120), CGPoint(x: 0, y: 0)]
        let output = Self.smooth(Self.jitter(Self.trace(corners), amount: 0.8, seed: 11), closed: true)
        for corner in corners.dropLast() {
            let nearest = output.map { FreehandSmoothing.distance($0, corner) }.min() ?? .infinity
            #expect(nearest <= Self.tolerance + 1.2, "corner \(corner) lost: nearest \(nearest)")
        }
    }

    @Test func jitterIsReduced() {
        let truth = Self.circle(radius: 80, count: 500)
        let input = Self.jitter(truth, amount: 1.5, seed: 21)
        let output = Self.smooth(input, closed: true)
        func radialError(_ points: [CGPoint]) -> Double {
            points.map { abs(FreehandSmoothing.distance($0, CGPoint(x: 200, y: 200)) - 80) }.reduce(0, +) / Double(points.count)
        }
        #expect(radialError(output) < radialError(input) * 0.8, "\(radialError(output)) vs \(radialError(input))")
    }

    @Test func aStraightNoisyLineCollapsesToFewPoints() {
        let input = Self.jitter(Self.trace([CGPoint(x: 0, y: 50), CGPoint(x: 400, y: 50)]), amount: 0.4, seed: 5)
        let output = Self.smooth(input)
        #expect(output.count == 3, "its ends and the widest point: \(output.count) points of \(input.count)")
        #expect(output.first == input.first && output.last == input.last)
    }

    @Test func degenerateInputsPassThrough() {
        #expect(Self.smooth([]).isEmpty)
        #expect(Self.smooth([CGPoint(x: 1, y: 1)]) == [CGPoint(x: 1, y: 1)])
        let two = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        #expect(Self.smooth(two) == two)
        #expect(Self.smooth(Array(repeating: CGPoint(x: 4, y: 4), count: 20)) == [CGPoint(x: 4, y: 4)])
        let tiny = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)]
        #expect(Self.smooth(tiny) == [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], "closer than the spacing: merged")
        #expect(FreehandSmoothing.smooth(Self.circle(radius: 30, count: 50), closed: true, spacing: 3, tolerance: 0).count == 50)
    }

    @Test func theEditorSmoothsDrawnOutlinesAndPreviewsTheSame() throws {
        var editor = AnnotationEditorTests.editor() // 1000 × 500 px, minimum side 6 px
        editor.setTool(.freehand)
        let stroke = Self.jitter(Self.circle(radius: 120, count: 300).map { CGPoint(x: $0.x + 200, y: $0.y) }, amount: 1.5, seed: 9)
        editor.beginGesture(at: stroke[0])
        stroke.dropFirst().forEach { editor.updateGesture(to: $0) }
        let preview = try #require(editor.previewShape)
        editor.endGesture()
        let shape = try #require(editor.bundle.annotations.first?.shape)
        #expect(shape == preview, "the preview is what gets committed")
        guard case let .freehand(points, closed) = shape else { Issue.record("not freehand"); return }
        #expect(closed)
        #expect(points.count >= 3 && points.count < stroke.count / 2, "\(points.count) of \(stroke.count) samples")
    }
}
