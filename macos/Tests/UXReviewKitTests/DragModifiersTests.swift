import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// HS2-Q5TA4C: ⇧ and ⌥ while drawing, resizing, moving, and cropping, as in other Mac drawing
/// apps. Geometry first, then the editor's gestures (media 1000 × 500 px, so 1 px = 10 units
/// across and 20 down), then the `--annotate` op. Spec: docs/06 §6.3.
struct DragModifiersTests {
    static func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
    static func r(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGRect { CGRect(x: x, y: y, width: width, height: height)
    }

    static let bounds = CGSize(width: 1000, height: 500)

    static func resize(_ rect: CGRect, _ handle: BoxHandle, _ target: CGPoint, _ modifiers: DragModifiers) -> CGRect {
        ModifiedBox.resize(rect, handle, to: target, modifiers: modifiers, within: BoxLimits(bounds: bounds, minimumSide: 6))
    }

    // MARK: Resizing a box

    @Test func noModifiersIsThePlainResize() {
        let frame = MediaFrame(width: 1000, height: 500)
        for handle in BoxHandle.allCases {
            for point in [Self.p(50, 40), Self.p(700, 480), Self.p(260, 140)] {
                #expect(
                    Self.resize(Self.r(200, 100, 200, 100), handle, point, [])
                        == Shape.resize(Self.r(200, 100, 200, 100), handle, to: point, minimumSide: 6, in: frame),
                    "\(handle) \(point)"
                )
            }
        }
    }

    @Test func shiftOnACornerKeepsTheAspectRatioFromTheOppositeCorner() {
        // 2:1 box; the larger change (×2 across) wins.
        #expect(Self.resize(Self.r(100, 100, 200, 100), .bottomRight, Self.p(500, 230), .constrain) == Self.r(100, 100, 400, 200))
        // Dragging the top-left corner in: anchored at the bottom right (300, 200); the larger of
        // the two scales (0.5 across, 0.6 down) wins.
        #expect(Self.resize(Self.r(100, 100, 200, 100), .topLeft, Self.p(200, 140), .constrain) == Self.r(180, 140, 120, 60))
        // Down to the minimum side, still 2:1.
        #expect(Self.resize(Self.r(100, 100, 200, 100), .bottomRight, Self.p(101, 101), .constrain) == Self.r(100, 100, 12, 6))
    }

    @Test func shiftOnAnEdgeScalesTheOtherSideAboutItsMiddle() {
        #expect(Self.resize(Self.r(100, 100, 200, 100), .right, Self.p(500, 0), .constrain) == Self.r(100, 50, 400, 200))
        #expect(Self.resize(Self.r(100, 100, 200, 100), .bottom, Self.p(0, 150), .constrain) == Self.r(150, 100, 100, 50))
    }

    @Test func optionResizesAboutTheCenter() {
        // Right edge to x 400: the left edge moves out by the same 100.
        #expect(Self.resize(Self.r(100, 100, 200, 100), .right, Self.p(400, 0), .fromCenter) == Self.r(0, 100, 400, 100))
        // A corner moves both axes about the center (500, 250): 150 and 20 either side.
        #expect(Self.resize(Self.r(400, 200, 200, 100), .bottomRight, Self.p(650, 270), .fromCenter) == Self.r(350, 230, 300, 40))
        // Past the media's edge on one side: limited so it stays centered and inside.
        #expect(Self.resize(Self.r(100, 100, 200, 100), .right, Self.p(700, 0), .fromCenter) == Self.r(0, 100, 400, 100))
    }

    @Test func shiftAndOptionTogetherScaleAboutTheCenterKeepingTheRatio() {
        #expect(
            Self.resize(Self.r(400, 200, 200, 100), .bottomRight, Self.p(700, 300), [.constrain, .fromCenter])
                == Self.r(300, 150, 400, 200)
        )
    }

    @Test func aConstrainedBoxShrinksToFitTheMediaKeepingItsRatio() {
        let fitted = Self.resize(Self.r(800, 300, 100, 50), .bottomRight, Self.p(1000, 500), .constrain)
        #expect(fitted == Self.r(800, 300, 200, 100))
        #expect(fitted.width / fitted.height == 2)
    }

    // MARK: Drawing a new box

    @Test func drawingWithShiftMakesASquareAndWithOptionGrowsFromTheCenter() {
        func drawn(_ start: CGPoint, _ target: CGPoint, _ modifiers: DragModifiers) -> CGRect {
            ModifiedBox.drawn(from: start, to: target, modifiers: modifiers, bounds: Self.bounds)
        }
        #expect(drawn(Self.p(100, 100), Self.p(300, 150), []) == Self.r(100, 100, 200, 50))
        #expect(drawn(Self.p(100, 100), Self.p(300, 150), .constrain) == Self.r(100, 100, 200, 200))
        #expect(drawn(Self.p(100, 100), Self.p(300, 150), .fromCenter) == Self.r(0, 50, 200, 100))
        #expect(drawn(Self.p(100, 100), Self.p(300, 150), [.constrain, .fromCenter]) == Self.r(0, 0, 200, 200))
        // Up and to the left: the square goes that way, as large as the room there allows.
        #expect(drawn(Self.p(500, 250), Self.p(300, 100), .constrain) == Self.r(300, 50, 200, 200))
        #expect(drawn(Self.p(950, 450), Self.p(1000, 300), .constrain) == Self.r(950, 400, 50, 50))
    }

    @Test func shiftSnapsAnArrowEndToTheNearest45Degrees() {
        func snapped(_ start: CGPoint, _ target: CGPoint) -> CGPoint { ModifiedBox.snapped(target, from: start, bounds: Self.bounds) }
        let flat = snapped(Self.p(100, 100), Self.p(300, 120))
        #expect(flat.y == 100 && abs(flat.x - (100 + (200.0 * 200 + 20 * 20).squareRoot())) < 0.001)
        let diagonal = snapped(Self.p(100, 100), Self.p(300, 290))
        #expect(abs(diagonal.x - diagonal.y) < 0.001 && diagonal.x > 100)
        // Pulled back along the 45° line at the media's edge.
        let edge = snapped(Self.p(950, 100), Self.p(1000, 160))
        #expect(abs(edge.x - 1000) < 0.001 && abs(edge.y - 150) < 0.001)
        #expect(snapped(Self.p(10, 10), Self.p(10, 10)) == Self.p(10, 10))
    }

    // MARK: The editor's gestures

    typealias Fixture = AnnotationEditorTests

    static func drag(_ editor: inout AnnotationEditor, _ points: [CGPoint], _ modifiers: DragModifiers) {
        editor.setDragModifiers(modifiers)
        Fixture.drag(&editor, points)
        editor.setDragModifiers([])
    }

    @Test func drawingWithModifiersInTheEditor() {
        var editor = Fixture.editor()
        editor.setTool(.rect)
        Self.drag(&editor, [Self.p(100, 100), Self.p(300, 150)], .constrain)
        #expect(editor.bundle.annotations.last?.shape == .rect(NormRect(x: 1000, y: 2000, width: 2000, height: 4000)))
        editor.setTool(.strike)
        Self.drag(&editor, [Self.p(500, 250), Self.p(600, 300)], .fromCenter)
        #expect(editor.bundle.annotations.last?.shape == .strike(NormRect(x: 4000, y: 4000, width: 2000, height: 2000)))
        editor.setTool(.arrow)
        Self.drag(&editor, [Self.p(100, 100), Self.p(300, 110)], .constrain)
        guard case let .arrow(points, _)? = editor.bundle.annotations.last?.shape else { Issue.record("no arrow"); return }
        #expect(points[0].y == points[1].y)
        // Each drawing is one undo step, as without modifiers.
        editor.undo()
        editor.undo()
        editor.undo()
        #expect(editor.bundle.annotations.isEmpty)
    }

    @Test func pressingOrReleasingAModifierMidDragReshapesItAtOnce() {
        var editor = Fixture.editor()
        editor.setTool(.rect)
        editor.beginGesture(at: Self.p(100, 100))
        editor.updateGesture(to: Self.p(300, 150))
        #expect(editor.previewShape == .rect(NormRect(x: 1000, y: 2000, width: 2000, height: 1000)))
        editor.setDragModifiers(.constrain) // ⇧ down, pointer still
        #expect(editor.previewShape == .rect(NormRect(x: 1000, y: 2000, width: 2000, height: 4000)))
        editor.setDragModifiers([]) // ⇧ up
        #expect(editor.previewShape == .rect(NormRect(x: 1000, y: 2000, width: 2000, height: 1000)))
        editor.setDragModifiers([.constrain, .fromCenter])
        editor.endGesture()
        #expect(editor.bundle.annotations.last?.shape == .rect(NormRect(x: 0, y: 0, width: 2000, height: 4000)))
        // No drag: changing modifiers changes nothing.
        let before = editor.bundle
        editor.setDragModifiers([])
        #expect(editor.bundle == before && editor.gesture == nil)
    }

    @Test func resizingAndMovingASelectedShapeWithModifiers() {
        var editor = Fixture.editor()
        Fixture.draw(&editor, .rect, [Self.p(100, 100), Self.p(300, 200)]) // 200 × 100, selected
        // ⇧ on the bottom-right handle: 2:1 kept.
        Self.drag(&editor, [Self.p(300, 200), Self.p(500, 230)], .constrain)
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 1000, y: 2000, width: 4000, height: 4000)))
        // ⌥ on the right handle (now at x 500): both sides move.
        Self.drag(&editor, [Self.p(500, 200), Self.p(550, 200)], .fromCenter)
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 500, y: 2000, width: 5000, height: 4000)))
        // ⇧ while moving: only along the larger direction.
        Self.drag(&editor, [Self.p(300, 200), Self.p(400, 220)], .constrain)
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 1500, y: 2000, width: 5000, height: 4000)))
        editor.undo()
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 500, y: 2000, width: 5000, height: 4000)))
    }

    @Test func croppingWithModifiers() {
        var editor = Fixture.editor()
        editor.setTool(.crop)
        Self.drag(&editor, [Self.p(100, 100), Self.p(300, 150)], .constrain)
        #expect(editor.cropRect(of: "m1") == PixelRect(x: 100, y: 100, width: 200, height: 200))
        // ⇧ on the crop's right edge keeps it square, centered on its middle.
        Self.drag(&editor, [Self.p(300, 200), Self.p(400, 200)], .constrain)
        #expect(editor.cropRect(of: "m1") == PixelRect(x: 100, y: 50, width: 300, height: 300))
        // ⌥ on the left edge: the right edge moves out too.
        Self.drag(&editor, [Self.p(100, 200), Self.p(50, 200)], .fromCenter)
        #expect(editor.cropRect(of: "m1") == PixelRect(x: 50, y: 50, width: 400, height: 300))
    }

    // MARK: The script op

    @Test func theModifiersOpParsesAndRejectsUnknownKeys() throws {
        let script = try JSONDecoder().decode(EditorScript.self, from: Data(#"""
        {"steps": [{"op": "modifiers", "keys": ["shift", "Option"]}, {"op": "modifiers", "keys": []}]}
        """#.utf8))
        #expect(script.steps == [.modifiers([.constrain, .fromCenter]), .modifiers([])])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EditorScript.self, from: Data(#"{"steps": [{"op": "modifiers", "keys": ["ctrl"]}]}"#.utf8))
        }
    }
}
