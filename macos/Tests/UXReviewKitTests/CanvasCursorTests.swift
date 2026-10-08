import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// The canvas cursor (`HS2-9RRP8G`, docs/06 §6.6): resize cursors on the crop rectangle's edges
/// and corners, an open hand inside a crop (closed while moving it), a crosshair elsewhere with the
/// Crop tool; arrow or crosshair with other tools. Images are 1000 × 500 px.
struct CanvasCursorTests {
    typealias Fixture = AnnotationEditorTests
    static func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    static func cropping() -> AnnotationEditor {
        var editor = CropToolTests.editor()
        editor.setTool(.crop)
        _ = editor.crop(to: CGRect(x: 100, y: 100, width: 500, height: 250))
        return editor
    }

    @Test func otherToolsShowAnArrowOrACrosshair() {
        var editor = CropToolTests.editor()
        #expect(editor.canvasCursor(at: Self.p(100, 100), tolerance: 6) == .arrow)
        for tool in EditorTool.allCases where tool != .select && tool != .crop {
            editor.setTool(tool)
            #expect(editor.canvasCursor(at: Self.p(100, 100), tolerance: 6) == .crosshair, "\(tool)")
            #expect(editor.canvasCursor(at: nil, tolerance: 6) == .crosshair)
        }
        // The Crop tool without media shows nothing to crop: a crosshair like a drawing tool.
        var empty = Fixture.editor(media: [])
        empty.setTool(.crop)
        #expect(empty.canvasCursor(at: Self.p(1, 1), tolerance: 6) == .crosshair)
    }

    @Test func edgesCornersAndTheInsideOfACrop() {
        let editor = Self.cropping()
        let cases: [(CGPoint, CanvasCursor)] = [
            (Self.p(100, 100), .resize(.topLeft)), (Self.p(605, 96), .resize(.topRight)),
            (Self.p(97, 352), .resize(.bottomLeft)), (Self.p(600, 350), .resize(.bottomRight)),
            (Self.p(350, 104), .resize(.top)), (Self.p(350, 348), .resize(.bottom)),
            (Self.p(95, 200), .resize(.left)), (Self.p(606, 200), .resize(.right)),
            (Self.p(350, 200), .openHand), (Self.p(50, 50), .crosshair), (Self.p(607, 200), .crosshair),
            (Self.p(350, 357), .crosshair), (Self.p(-20, -20), .crosshair),
        ]
        for (point, expected) in cases {
            #expect(editor.canvasCursor(at: point, tolerance: 6) == expected, "\(point)")
            // The cursor shows exactly what a press there would grab.
            #expect(
                editor.canvasCursor(at: point, tolerance: 6) == editor.cropHandle(at: point, tolerance: 6).map(CanvasCursor.init)
                    ?? .crosshair
            )
        }
        #expect(editor.canvasCursor(at: nil, tolerance: 6) == .crosshair)
    }

    @Test func theToleranceFollowsTheZoom() {
        // 7 screen points: 3.5 px at 200 %, 14 px at 50 %.
        let editor = Self.cropping()
        #expect(editor.canvasCursor(at: Self.p(90, 200), tolerance: 3.5) == .crosshair)
        #expect(editor.canvasCursor(at: Self.p(90, 200), tolerance: 14) == .resize(.left))
        #expect(editor.canvasCursor(at: Self.p(103, 200), tolerance: 3.5) == .resize(.left))
        #expect(editor.canvasCursor(at: Self.p(106, 200), tolerance: 3.5) == .openHand)
    }

    @Test func anUncroppedOriginalResizesFromItsEdgesAndDrawsInside() {
        var editor = CropToolTests.editor()
        editor.setTool(.crop)
        #expect(editor.canvasCursor(at: Self.p(2, 250), tolerance: 6) == .resize(.left))
        #expect(editor.canvasCursor(at: Self.p(998, 497), tolerance: 6) == .resize(.bottomRight))
        #expect(editor.canvasCursor(at: Self.p(500, 250), tolerance: 6) == .crosshair) // a new crop
    }

    @Test func aTinyCropShowsTheNearerCorner() {
        var editor = Self.cropping()
        _ = editor.crop(to: CGRect(x: 100, y: 100, width: 8, height: 8))
        #expect(editor.canvasCursor(at: Self.p(101, 103), tolerance: 6) == .resize(.topLeft))
        #expect(editor.canvasCursor(at: Self.p(107, 105), tolerance: 6) == .resize(.bottomRight))
        #expect(editor.canvasCursor(at: Self.p(101, 106), tolerance: 6) == .resize(.bottomLeft))
    }

    @Test func duringAGestureTheCursorFollowsTheGrabbedHandle() {
        var editor = Self.cropping()
        editor.hitTolerance = 6
        // Moving: a closed hand wherever the pointer goes, even off the crop or the media.
        editor.beginGesture(at: Self.p(350, 200))
        #expect(editor.canvasCursor(at: Self.p(350, 200), tolerance: 6) == .closedHand)
        editor.updateGesture(to: Self.p(-50, 900))
        #expect(editor.canvasCursor(at: Self.p(-50, 900), tolerance: 6) == .closedHand)
        #expect(editor.canvasCursor(at: nil, tolerance: 6) == .closedHand)
        editor.endGesture()
        #expect(editor.canvasCursor(at: Self.p(-50, 900), tolerance: 6) == .crosshair)
        // Resizing from the right edge: left-right even when dragged into the inside.
        let crop = editor.cropOverlay ?? .zero
        editor.beginGesture(at: Self.p(crop.maxX, crop.midY))
        #expect(editor.canvasCursor(at: Self.p(crop.maxX, crop.midY), tolerance: 6) == .resize(.right))
        editor.updateGesture(to: Self.p(crop.midX, crop.midY))
        #expect(editor.canvasCursor(at: Self.p(crop.midX, crop.midY), tolerance: 6) == .resize(.right))
        editor.cancelGesture()
        #expect(editor.canvasCursor(at: Self.p(crop.midX, crop.midY), tolerance: 6) == .openHand)
        // Drawing a new crop: a crosshair, even over the old crop's edge.
        editor.beginGesture(at: Self.p(20, 20))
        editor.updateGesture(to: Self.p(crop.minX, crop.midY))
        #expect(editor.canvasCursor(at: Self.p(crop.minX, crop.midY), tolerance: 6) == .crosshair)
        editor.endGesture()
        // Undo / redo move the crop under a still pointer: the cursor follows the crop.
        // (The move above clamped the crop to x 0, so the new one spans x 0…20, y 20…375.)
        let point = Self.p(10, 100)
        #expect(editor.canvasCursor(at: point, tolerance: 6) == .openHand)
        editor.undo()
        #expect(editor.canvasCursor(at: point, tolerance: 6) == .crosshair)
        // Leaving the Crop tool mid-hover: the tool's cursor.
        editor.setTool(.rect)
        #expect(editor.canvasCursor(at: point, tolerance: 6) == .crosshair)
        editor.setTool(.select)
        #expect(editor.canvasCursor(at: point, tolerance: 6) == .arrow)
    }

    @Test func everyCropHandleHasItsCursor() {
        #expect(CanvasCursor(.move) == .openHand)
        for box in BoxHandle.allCases {
            #expect(CanvasCursor(.edge(box)) == .resize(box))
        }
    }
}
