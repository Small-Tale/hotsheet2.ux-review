import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// Crop math and the crop's place in the editor's history. Media is 1000 × 500 px.
struct ImageCropTests {
    typealias Fixture = AnnotationEditorTests

    let frame = MediaFrame(width: 1000, height: 500)
    let crop = PixelRect(x: 100, y: 100, width: 500, height: 250)

    @Test func snappingRoundsOutwardAndClips() {
        #expect(
            PixelRect.snapping(CGRect(x: 10.4, y: 10.6, width: 20.2, height: 5), width: 100, height: 100)
                == PixelRect(x: 10, y: 10, width: 21, height: 6)
        )
        #expect(
            PixelRect.snapping(CGRect(x: 90, y: -10, width: 50, height: 30), width: 100, height: 100)
                == PixelRect(x: 90, y: 0, width: 10, height: 20)
        )
        #expect(PixelRect.snapping(CGRect(x: 200, y: 0, width: 5, height: 5), width: 100, height: 100) == nil)
        #expect(
            PixelRect.snapping(CGRect(x: 50, y: 50, width: -20, height: -20), width: 100, height: 100)
                == PixelRect(x: 30, y: 30, width: 20, height: 20)
        )
    }

    @Test func boxesAreClippedAndMovedIntoTheCrop() {
        // Fully inside: 200…300 × 150…200 px → crop-local 100…200 × 50…100 of 500 × 250.
        let inside = Shape.rect(frame.norm(CGRect(x: 200, y: 150, width: 100, height: 50)))
        #expect(ImageCrop.transform(inside, from: frame, crop: crop) == .rect(NormRect(x: 2000, y: 2000, width: 2000, height: 2000)))
        // Sticking out on the left/top: clipped to the crop's edge.
        let straddling = Shape.strike(frame.norm(CGRect(x: 0, y: 0, width: 200, height: 150)))
        #expect(ImageCrop.transform(straddling, from: frame, crop: crop) == .strike(NormRect(x: 0, y: 0, width: 2000, height: 2000)))
        // Outside, and only touching an edge: removed.
        #expect(ImageCrop.transform(.rect(frame.norm(CGRect(x: 700, y: 0, width: 100, height: 50))), from: frame, crop: crop) == nil)
        #expect(ImageCrop.transform(.rect(frame.norm(CGRect(x: 0, y: 0, width: 100, height: 100))), from: frame, crop: crop) == nil)
    }

    @Test func pointsAreMovedOrPulledToTheEdge() {
        #expect(
            ImageCrop.transform(.insertion(frame.norm(CGPoint(x: 350, y: 225))), from: frame, crop: crop)
                == .insertion(NormPoint(x: 5000, y: 5000))
        )
        #expect(
            ImageCrop.transform(.insertion(frame.norm(CGPoint(x: 600, y: 350))), from: frame, crop: crop)
                == .insertion(NormPoint(x: 10000, y: 10000))
        ) // on the far corner: kept
        #expect(ImageCrop.transform(.insertion(frame.norm(CGPoint(x: 50, y: 50))), from: frame, crop: crop) == nil)

        // An arrow from outside into the crop keeps its head; its tail is pulled to the edge.
        let arrow = Shape.arrow(points: [frame.norm(CGPoint(x: 0, y: 225)), frame.norm(CGPoint(x: 350, y: 225))])
        #expect(ImageCrop.transform(arrow, from: frame, crop: crop) == .arrow(points: [
            NormPoint(x: 0, y: 5000),
            NormPoint(x: 5000, y: 5000),
        ]))
        let outside = Shape.freehand(
            points: [CGPoint(x: 700, y: 400), CGPoint(x: 800, y: 400), CGPoint(x: 800, y: 450)].map(frame.norm),
            closed: true
        )
        #expect(ImageCrop.transform(outside, from: frame, crop: crop) == nil)
    }

    /// HS2-71SSJG: a crop maps annotations exactly and hides the ones outside instead of
    /// removing them; restoring or undoing brings them back unchanged.
    @Test func croppingInTheEditorMovesAnnotationsAndHidesOutsiders() {
        var editor = Fixture.editor()
        Fixture.draw(&editor, .rect, [Fixture.p(200, 150), Fixture.p(300, 200)]) // inside
        Fixture.draw(&editor, .insertion, [Fixture.p(900, 450)]) // outside
        editor.setTool(.crop)
        Fixture.drag(&editor, [Fixture.p(100, 100), Fixture.p(600, 350)])
        #expect(editor.tool == .select)
        #expect(editor.currentMedia?.pixelWidth == 500 && editor.currentMedia?.pixelHeight == 250)
        #expect(editor.document.crops["m1"] == crop)
        #expect(editor.bundle.annotations.map(\.shape) == [
            .rect(NormRect(x: 2000, y: 2000, width: 2000, height: 2000)),
            .insertion(NormPoint(x: 16000, y: 14000)), // kept, beyond the crop
        ])
        #expect(editor.isOutsideEdit(editor.bundle.annotations[1]))
        #expect(editor.visibleAnnotations(on: "m1").map(\.id) == ["a1"])
        #expect(editor.hitTest(Fixture.p(499, 249)) == nil)
        #expect(editor.selection == nil) // the selected insertion is now outside the crop
        #expect(
            editor.message == "Cropped to 500 × 250 px. 1 annotation outside the crop is hidden."
        )
        // What would be submitted leaves it out and is valid.
        #expect(editor.submissionBundle.annotations.map(\.id) == ["a1"])
        #expect(editor.submissionBundle.validate().isEmpty)

        // A second crop composes with the first, relative to the original image.
        let cropped = editor.crop(to: CGRect(x: 50, y: 25, width: 200, height: 100))
        #expect(cropped)
        #expect(editor.document.crops["m1"] == PixelRect(x: 150, y: 125, width: 200, height: 100))

        editor.undo()
        #expect(editor.document.crops["m1"] == crop)
        editor.undo()
        #expect(editor.document.crops["m1"] == nil)
        #expect(editor.currentMedia?.pixelWidth == 1000)
        #expect(editor.bundle.annotations.map(\.shape).last == .insertion(MediaFrame(width: 1000, height: 500).norm(Fixture.p(900, 450))))
        editor.redo()
        editor.redo()
        #expect(editor.document.crops["m1"] == PixelRect(x: 150, y: 125, width: 200, height: 100))
        // Restore Original after two crops: every annotation is back exactly where it was drawn.
        let restored = editor.restoreOriginal()
        #expect(restored)
        #expect(editor.bundle.annotations.map(\.shape) == [
            .rect(MediaFrame(width: 1000, height: 500).norm(CGRect(x: 200, y: 150, width: 100, height: 50))),
            .insertion(MediaFrame(width: 1000, height: 500).norm(Fixture.p(900, 450))),
        ])
        #expect(editor.visibleAnnotations(on: "m1").count == 2)
    }

    @Test func refusedCropsChangeNothing() {
        var editor = Fixture.editor(media: [Fixture.media(), Fixture.media("v1", kind: .video)])
        let tiny = editor.crop(to: CGRect(x: 0, y: 0, width: 5, height: 100))
        #expect(!tiny)
        #expect(editor.message?.contains("at least 8") == true)
        let whole = editor.crop(to: CGRect(x: -10, y: -10, width: 2000, height: 2000)) // the whole image
        #expect(!whole)
        editor.setTool(.crop)
        Fixture.drag(&editor, [Fixture.p(10, 10)]) // a click
        #expect(editor.document.crops.isEmpty && !editor.canUndo)

        editor.show(mediaId: "v1")
        editor.setTool(.crop)
        editor.beginGesture(at: Fixture.p(10, 10))
        #expect(editor.gesture == nil)
        #expect(editor.message == "Videos can't be cropped.")
        let video = editor.crop(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(!video)
    }

    @Test func resetCropMapsAnnotationsBackOntoTheOriginal() {
        var editor = Fixture.editor()
        _ = editor.crop(to: crop.cgRect)
        Fixture.draw(&editor, .rect, [Fixture.p(0, 0), Fixture.p(100, 50)]) // crop-local
        let reset = editor.resetCrop()
        #expect(reset)
        #expect(editor.document.crops["m1"] == nil)
        #expect(editor.currentMedia?.pixelWidth == 1000)
        #expect(editor.bundle.annotations[0].shape == .rect(NormRect(x: 1000, y: 2000, width: 1000, height: 1000)))
        let again = editor.resetCrop()
        #expect(!again) // nothing to reset
        editor.undo()
        #expect(editor.document.crops["m1"] == crop)
    }
}

/// Pixel ↔ normalized conversion and hit testing.
struct ShapeGeometryTests {
    let frame = MediaFrame(width: 1000, height: 500)

    @Test func conversionsRoundTripAndClamp() {
        #expect(frame.norm(CGPoint(x: 250, y: 125)) == NormPoint(x: 2500, y: 2500))
        #expect(frame.pixel(NormPoint(x: 2500, y: 2500)) == CGPoint(x: 250, y: 125))
        #expect(frame.norm(CGPoint(x: -5, y: 9999)) == NormPoint(x: 0, y: 10000))
        #expect(frame.norm(CGPoint(x: Double.nan, y: 0)) == NormPoint(x: 0, y: 0))
        #expect(frame.norm(CGRect(x: 990, y: 495, width: 50, height: 50)) == NormRect(x: 9900, y: 9900, width: 100, height: 100))
        #expect(frame.norm(CGRect(x: 2000, y: 2000, width: 5, height: 5)).isValid) // fully outside still validates
        #expect(MediaFrame(width: 0, height: 0).width == 1) // never divides by zero
    }

    @Test func hitDistancePerShape() {
        let box = Shape.rect(frame.norm(CGRect(x: 100, y: 100, width: 100, height: 100)))
        #expect(box.hitDistance(CGPoint(x: 150, y: 150), in: frame, tolerance: 5) == 0)
        #expect(box.hitDistance(CGPoint(x: 204, y: 150), in: frame, tolerance: 5) == 4)
        #expect(box.hitDistance(CGPoint(x: 210, y: 150), in: frame, tolerance: 5) == nil)

        let arrow = Shape.arrow(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)].map(frame.norm))
        #expect(arrow.hitDistance(CGPoint(x: 50, y: 3), in: frame, tolerance: 5) == 3)
        #expect(arrow.hitDistance(CGPoint(x: 50, y: 30), in: frame, tolerance: 5) == nil)

        let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100)].map(frame.norm)
        #expect(Shape.freehand(points: triangle, closed: true).hitDistance(CGPoint(x: 20, y: 20), in: frame, tolerance: 5) == 0)
        // Open outlines are only hit near their stroke, not inside.
        #expect(Shape.freehand(points: triangle, closed: false).hitDistance(CGPoint(x: 20, y: 20), in: frame, tolerance: 5) == nil)

        let caret = Shape.insertion(frame.norm(CGPoint(x: 500, y: 250)))
        #expect(caret.hitDistance(CGPoint(x: 500, y: 240), in: frame, tolerance: 6) == 0) // on the bar above
        #expect(caret.hitDistance(CGPoint(x: 530, y: 250), in: frame, tolerance: 6) == nil)
    }

    @Test func handlesPerShape() {
        #expect(Shape.rect(NormRect(x: 0, y: 0, width: 5000, height: 5000)).handles(in: frame).count == 8)
        #expect(Shape.arrow(points: [NormPoint(x: 0, y: 0), NormPoint(x: 1, y: 1), NormPoint(x: 2, y: 2)]).handles(in: frame).count == 3)
        #expect(Shape.insertion(NormPoint(x: 0, y: 0)).handles(in: frame).isEmpty)
        let handles = Shape.rect(NormRect(x: 0, y: 0, width: 10000, height: 10000)).handles(in: frame)
        #expect(handles.first { $0.handle == .box(.right) }?.position == CGPoint(x: 1000, y: 250))
    }

    @Test func translationKeepsEveryPointOnTheMedia() {
        let shape = Shape.freehand(
            points: [NormPoint(x: 100, y: 100), NormPoint(x: 9000, y: 500), NormPoint(x: 400, y: 9900)],
            closed: true
        )
        let moved = shape.translated(dx: 5000, dy: 5000)
        #expect(moved == .freehand(
            points: [NormPoint(x: 1100, y: 200), NormPoint(x: 10000, y: 600), NormPoint(x: 1400, y: 10000)],
            closed: true
        ))
        #expect(shape.translated(dx: -99999, dy: 0).allPoints.map(\.x).min() == 0)
    }
}
