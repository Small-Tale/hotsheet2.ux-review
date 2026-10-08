import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// The Crop tool (HS2-4N722Z, docs/06 §6.6): while it is chosen the canvas shows the original
/// with one crop rectangle that can be drawn again, moved, or resized; other tools show the
/// cropped media. States: tool (Crop / another) × crop (none / some) × gesture (none / drawing /
/// moving / resizing); transitions: tool switches, crop gestures, undo / redo, Restore Original,
/// and switching captures. Images are 1000 × 500 px.
struct CropToolTests {
    typealias Fixture = AnnotationEditorTests

    static func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
    static let original = MediaFrame(width: 1000, height: 500)

    /// An image with a rectangle and an insertion drawn on the original, plus a second image.
    static func editor() -> AnnotationEditor {
        var editor = Fixture.editor(media: [Fixture.media("m1"), Fixture.media("m2"), Fixture.media("v1", kind: .video)])
        Fixture.draw(&editor, .rect, [p(200, 150), p(300, 200)])
        Fixture.draw(&editor, .insertion, [p(900, 450)])
        editor.show(mediaId: "m2")
        Fixture.draw(&editor, .arrow, [p(100, 100), p(400, 300)])
        editor.show(mediaId: "m1")
        return editor
    }

    /// The shapes as drawn, on the original.
    static let drawn: [String: Shape] = [
        "a1": .rect(original.norm(CGRect(x: 200, y: 150, width: 100, height: 50))),
        "a2": .insertion(original.norm(p(900, 450))),
        "a3": .arrow(points: [original.norm(p(100, 100)), original.norm(p(400, 300))]),
    ]

    // MARK: Showing the original

    @Test func theCropToolShowsTheOriginalAndOtherToolsTheCrop() {
        var editor = Self.editor()
        #expect(!editor.showsOriginal && editor.cropOverlay == nil)
        editor.setTool(.crop)
        #expect(editor.showsOriginal)
        #expect(editor.message == AnnotationEditor.cropHint)
        #expect(editor.canvasFrame == Self.original)
        #expect(editor.cropOverlay == CGRect(x: 0, y: 0, width: 1000, height: 500)) // uncropped: the whole original

        Fixture.drag(&editor, [Self.p(100, 100), Self.p(600, 350)])
        #expect(editor.document.crops["m1"] == PixelRect(x: 100, y: 100, width: 500, height: 250))
        #expect(editor.tool == .crop, "the Crop tool stays chosen after the first rectangle")
        #expect(editor.showsOriginal && editor.canvasFrame == Self.original && editor.canvasOrigin == .zero)
        #expect(editor.cropOverlay == CGRect(x: 100, y: 100, width: 500, height: 250))
        #expect(editor.currentFrame == MediaFrame(width: 500, height: 250))
        // Annotations show in the original's space, the outsider included (under the dim).
        #expect(editor.annotationsInOriginal(on: "m1").map(\.shape) == [Self.drawn["a1"], Self.drawn["a2"]])

        editor.setTool(.select)
        #expect(!editor.showsOriginal && editor.cropOverlay == nil)
        #expect(editor.canvasFrame == MediaFrame(width: 500, height: 250))
        #expect(editor.canvasOrigin == CGPoint(x: 100, y: 100))
        #expect(editor.visibleAnnotations(on: "m1").map(\.id) == ["a1"])
        // Hit testing and drawing work in the cropped frame: the box is at crop-local 100…200.
        #expect(editor.hitTest(Self.p(150, 75))?.id == "a1")
        Fixture.draw(&editor, .rect, [Self.p(0, 0), Self.p(500, 250)])
        #expect(editor.annotation("a4")?.shape == .rect(NormRect(x: 0, y: 0, width: 10000, height: 10000)))
        editor.setTool(.crop)
        #expect(
            editor.annotationsInOriginal(on: "m1").last?
                .shape == .rect(Self.original.norm(CGRect(x: 100, y: 100, width: 500, height: 250)))
        )
    }

    /// HS2-M03YP2: videos crop with the same tool and rules, with even sides (H.264).
    @Test func videosCropLikeImagesWithEvenSidesAndEmptyReviewsNeverShowTheOriginal() {
        var editor = Self.editor()
        editor.show(mediaId: "v1")
        editor.setTool(.crop)
        #expect(editor.showsOriginal && editor.message == AnnotationEditor.cropHint)
        #expect(editor.cropOverlay == CGRect(x: 0, y: 0, width: 1000, height: 500))
        Fixture.drag(&editor, [Self.p(101, 51), Self.p(400.5, 250)]) // 101…401 × 51…250: odd sides
        #expect(editor.document.crops["v1"] == PixelRect(x: 101, y: 51, width: 300, height: 200))
        Fixture.drag(&editor, [Self.p(401, 150), Self.p(500.2, 150)]) // the right edge to 501: 400 wide
        #expect(editor.document.crops["v1"] == PixelRect(x: 101, y: 51, width: 400, height: 200))
        Fixture.drag(&editor, [Self.p(101, 51), Self.p(0, 0)]) // top-left out to the corner: 501 × 251
        #expect(editor.document.crops["v1"] == PixelRect(x: 0, y: 0, width: 502, height: 252), "grown right to even")
        #expect(editor.currentFrame == MediaFrame(width: 502, height: 252) && editor.tool == .crop)
        #expect(editor.message == "Cropped to 502 × 252 px.")
        // Restore Original removes the crop and the trim as one step.
        let trimmed = editor.trim(to: TimeRange(startMs: 1000, endMs: 3000))
        #expect(trimmed)
        let depth = editor.undoStack.count
        let restored = editor.restoreOriginal()
        #expect(restored && editor.document.crops["v1"] == nil && editor.document.trims["v1"] == nil)
        #expect(editor.currentFrame == Self.original && editor.currentDurationMs == 4000)
        #expect(editor.undoStack.count == depth + 1)
        editor.undo()
        #expect(editor.document.crops["v1"] == PixelRect(x: 0, y: 0, width: 502, height: 252))
        #expect(editor.document.trims["v1"] == TimeRange(startMs: 1000, endMs: 3000))

        var empty = AnnotationEditor(bundle: TestSupport.bundle(media: []))
        empty.setTool(.crop)
        #expect(!empty.showsOriginal && empty.canvasFrame == nil && empty.cropOverlay == nil)
        empty.beginGesture(at: Self.p(1, 1))
        #expect(empty.gesture == nil)
    }

    // MARK: Adjusting

    @Test func pressesGrabEdgesCornersAndTheInside() {
        var editor = Self.editor()
        editor.setTool(.crop)
        editor.hitTolerance = 6
        // Uncropped: the original's edges resize, the inside draws a new rectangle.
        #expect(editor.cropHandle(at: Self.p(2, 250)) == .edge(.left))
        #expect(editor.cropHandle(at: Self.p(998, 497)) == .edge(.bottomRight))
        #expect(editor.cropHandle(at: Self.p(500, 250)) == nil)
        _ = editor.crop(to: CGRect(x: 100, y: 100, width: 500, height: 250))
        let cases: [(CGPoint, CropHandle?)] = [
            (Self.p(100, 100), .edge(.topLeft)), (Self.p(605, 96), .edge(.topRight)), (Self.p(97, 352), .edge(.bottomLeft)),
            (Self.p(600, 350), .edge(.bottomRight)), (Self.p(350, 104), .edge(.top)), (Self.p(350, 348), .edge(.bottom)),
            (Self.p(95, 200), .edge(.left)), (Self.p(606, 200), .edge(.right)),
            (Self.p(350, 200), .move), (Self.p(50, 50), nil), (Self.p(607, 200), nil), (Self.p(350, 357), nil),
        ]
        for (point, expected) in cases {
            #expect(editor.cropHandle(at: point) == expected, "\(point)")
        }
        // A crop smaller than twice the tolerance: the nearer edges win, so every press on it
        // resizes from the closest corner.
        _ = editor.crop(to: CGRect(x: 100, y: 100, width: 8, height: 8))
        #expect(editor.cropHandle(at: Self.p(101, 103)) == .edge(.topLeft))
        #expect(editor.cropHandle(at: Self.p(107, 105)) == .edge(.bottomRight))
    }

    @Test func movingAndResizingReplaceTheCropOneUndoStepEach() {
        var editor = Self.editor()
        editor.setTool(.crop)
        Fixture.drag(&editor, [Self.p(100, 100), Self.p(600, 350)])
        let depth = editor.undoStack.count

        // Move by whole pixels, inside the original.
        Fixture.drag(&editor, [Self.p(300, 200), Self.p(320, 190), Self.p(350.4, 179.6)])
        #expect(editor.document.crops["m1"] == PixelRect(x: 150, y: 80, width: 500, height: 250))
        Fixture.drag(&editor, [Self.p(300, 200), Self.p(-900, -900)]) // clamped to the top left
        #expect(editor.document.crops["m1"] == PixelRect(x: 0, y: 0, width: 500, height: 250))
        Fixture.drag(&editor, [Self.p(300, 200), Self.p(3000, 3000)]) // and to the bottom right
        #expect(editor.document.crops["m1"] == PixelRect(x: 500, y: 250, width: 500, height: 250))
        // Resize: the left edge, then the top-left corner, then past the right edge (never flips).
        Fixture.drag(&editor, [Self.p(500, 400), Self.p(400.3, 400)])
        #expect(editor.document.crops["m1"] == PixelRect(x: 400, y: 250, width: 600, height: 250))
        Fixture.drag(&editor, [Self.p(400, 250), Self.p(300, 150)])
        #expect(editor.document.crops["m1"] == PixelRect(x: 300, y: 150, width: 700, height: 350))
        Fixture.drag(&editor, [Self.p(300, 300), Self.p(2000, 300)])
        #expect(editor.document.crops["m1"] == PixelRect(x: 992, y: 150, width: 8, height: 350))
        #expect(editor.tool == .crop)
        #expect(editor.undoStack.count == depth + 6)
        #expect(editor.currentMedia?.pixelWidth == 8 && editor.currentMedia?.pixelHeight == 350)
        #expect(editor.message == "Cropped to 8 × 350 px. 2 annotations outside the crop are hidden.")

        // Undo walks back through every crop; redo forward again.
        let expected: [PixelRect] = [
            PixelRect(x: 300, y: 150, width: 700, height: 350), PixelRect(x: 400, y: 250, width: 600, height: 250),
            PixelRect(x: 500, y: 250, width: 500, height: 250), PixelRect(x: 0, y: 0, width: 500, height: 250),
            PixelRect(x: 150, y: 80, width: 500, height: 250), PixelRect(x: 100, y: 100, width: 500, height: 250),
        ]
        for crop in expected {
            editor.undo()
            #expect(editor.document.crops["m1"] == crop)
            #expect(editor.currentFrame == MediaFrame(width: Double(crop.width), height: Double(crop.height)))
        }
        for crop in expected.reversed().dropFirst() {
            editor.redo()
            #expect(editor.document.crops["m1"] == crop)
        }
        // Annotations never drifted through all of that.
        #expect(editor.annotationsInOriginal(on: "m1").map(\.shape) == [Self.drawn["a1"], Self.drawn["a2"]])
    }

    @Test func aNewRectangleReplacesTheCropAndClicksDoNothing() {
        var editor = Self.editor()
        editor.setTool(.crop)
        editor.minimumSide = 6
        Fixture.drag(&editor, [Self.p(100, 100), Self.p(600, 350)])
        let depth = editor.undoStack.count
        Fixture.drag(&editor, [Self.p(700, 50), Self.p(950, 480)]) // outside the crop: a new one
        #expect(editor.document.crops["m1"] == PixelRect(x: 700, y: 50, width: 250, height: 430))
        #expect(editor.annotationsInOriginal(on: "m1").map(\.shape) == [Self.drawn["a1"], Self.drawn["a2"]])
        #expect(editor.visibleAnnotations(on: "m1").map(\.id) == ["a2"])
        // A click, a tiny drag, or a press and release in place changes nothing and says nothing.
        editor.setTool(.select)
        editor.setTool(.crop)
        Fixture.drag(&editor, [Self.p(50, 50)])
        Fixture.drag(&editor, [Self.p(50, 50), Self.p(54, 53)])
        Fixture.drag(&editor, [Self.p(800, 200), Self.p(800, 200)]) // moving by nothing
        #expect(editor.undoStack.count == depth + 1)
        #expect(editor.message == nil)
        // A drag big enough to see but under 8 px is refused with the reason.
        Fixture.drag(&editor, [Self.p(50, 50), Self.p(57, 100)])
        #expect(editor.message == "A crop must be at least 8 × 8 pixels.")
        #expect(editor.undoStack.count == depth + 1)
    }

    @Test func aCropOutToTheWholeOriginalRemovesIt() {
        var editor = Self.editor()
        editor.setTool(.crop)
        Fixture.drag(&editor, [Self.p(100, 100), Self.p(600, 350)])
        Fixture.drag(&editor, [Self.p(100, 100), Self.p(-50, -50)]) // top-left corner out
        Fixture.drag(&editor, [Self.p(600, 350), Self.p(2000, 2000)]) // bottom-right corner out
        #expect(editor.document.crops["m1"] == nil)
        #expect(editor.message == "Showing the whole capture.")
        #expect(!editor.canRestoreOriginal)
        #expect(editor.currentFrame == Self.original)
        #expect(editor.bundle.annotations.filter { $0.mediaId == "m1" }.map(\.shape) == [Self.drawn["a1"], Self.drawn["a2"]])
        // Then a crop to the whole original again does nothing.
        let again = editor.crop(to: CGRect(x: 0, y: 0, width: 1000, height: 500))
        #expect(!again)
    }

    // MARK: Interruptions, Restore Original, other captures

    @Test func interruptedCropGesturesLeaveNothingBehind() {
        var editor = Self.editor()
        editor.setTool(.crop)
        Fixture.drag(&editor, [Self.p(100, 100), Self.p(600, 350)])
        let before = editor.document
        let depth = editor.undoStack.count
        let interruptions: [(String, (inout AnnotationEditor) -> Void)] = [
            ("Esc", { $0.cancelGesture() }),
            ("undo", { $0.undo() }),
            ("redo", { $0.redo() }),
            ("other media", { $0.show(mediaId: "m2") }),
            ("another tool", { $0.setTool(.rect) }),
            ("a new press", { $0.beginGesture(at: Self.p(10, 10)); $0.cancelGesture() }),
        ]
        for (name, interrupt) in interruptions {
            editor.show(mediaId: "m1")
            editor.setTool(.crop)
            for start in [Self.p(300, 200), Self.p(600, 200), Self.p(800, 450)] { // move, resize, new
                editor.beginGesture(at: start)
                editor.updateGesture(to: Self.p(start.x - 60, start.y - 40))
                #expect(editor.previewCrop != nil && editor.cropOverlay == editor.previewCrop, "\(name)")
                interrupt(&editor)
                #expect(editor.gesture == nil && editor.previewCrop == nil, "\(name)")
                if name == "undo" {
                    // Undo cancels the drag first, then undoes the crop itself; put it back.
                    editor.redo()
                }
                #expect(editor.document == before, "\(name)")
                #expect(editor.undoStack.count == depth, "\(name)")
                editor.show(mediaId: "m1")
                editor.setTool(.crop)
            }
        }
    }

    @Test func restoreOriginalAndUndoWhileTheCropToolShowsTheOriginal() {
        var editor = Self.editor()
        editor.setTool(.crop)
        Fixture.drag(&editor, [Self.p(100, 100), Self.p(600, 350)])
        Fixture.drag(&editor, [Self.p(300, 200), Self.p(350, 220)])
        #expect(editor.canRestoreOriginal)
        let restored = editor.restoreOriginal()
        #expect(restored)
        #expect(editor.tool == .crop && editor.showsOriginal)
        #expect(editor.cropOverlay == CGRect(x: 0, y: 0, width: 1000, height: 500))
        #expect(editor.bundle.annotations.filter { $0.mediaId == "m1" }.map(\.shape) == [Self.drawn["a1"], Self.drawn["a2"]])
        // Restore Original is one undo step, back to the moved crop.
        editor.undo()
        #expect(editor.document.crops["m1"] == PixelRect(x: 150, y: 120, width: 500, height: 250))
        #expect(editor.cropOverlay == CGRect(x: 150, y: 120, width: 500, height: 250))
        editor.redo()
        #expect(editor.document.crops["m1"] == nil)
        // Restore Original again with nothing to restore does nothing.
        let nothing = editor.restoreOriginal()
        #expect(!nothing)
    }

    @Test func eachCaptureKeepsItsOwnCropAcrossSwitches() {
        var editor = Self.editor()
        editor.setTool(.crop)
        Fixture.drag(&editor, [Self.p(100, 100), Self.p(600, 350)])
        editor.show(mediaId: "m2")
        #expect(editor.tool == .crop && editor.showsOriginal)
        #expect(editor.cropOverlay == CGRect(x: 0, y: 0, width: 1000, height: 500))
        Fixture.drag(&editor, [Self.p(50, 50), Self.p(450, 350)])
        #expect(editor.document.crops == [
            "m1": PixelRect(x: 100, y: 100, width: 500, height: 250),
            "m2": PixelRect(x: 50, y: 50, width: 400, height: 300),
        ])
        editor.show(mediaId: "v1") // a video, uncropped: the whole frame
        #expect(editor.showsOriginal && editor.cropOverlay == CGRect(x: 0, y: 0, width: 1000, height: 500))
        editor.show(mediaId: "m1")
        #expect(editor.cropOverlay == CGRect(x: 100, y: 100, width: 500, height: 250))
        // Undo jumps back to the capture whose crop it undoes.
        editor.undo()
        #expect(editor.currentMediaId == "m2" && editor.document.crops["m2"] == nil)
        #expect(editor.document.crops["m1"] == PixelRect(x: 100, y: 100, width: 500, height: 250))
        editor.undo()
        #expect(editor.currentMediaId == "m1" && editor.document.crops.isEmpty)
        #expect(editor.annotationsInOriginal(on: "m2").map(\.shape) == [Self.drawn["a3"]])
    }
}

/// The transition walk.
extension CropToolTests {
    /// A deterministic pseudo-random generator, so a failing walk can be replayed.
    struct Walk: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// Thousands of interleaved steps (tool switches, new crops, moves, resizes, cancelled drags,
    /// undo, redo, Restore Original, switching captures), checking after each that the canvas
    /// space follows the rules and that no annotation ever drifts from where it was drawn.
    @Test(.timeLimit(.minutes(1))) func randomWalksKeepEveryInvariant() {
        // (Crop tool showing the original, current image cropped, last step changed the crop)
        var visited: Set<[Bool]> = []
        for seed in UInt64(1) ... 12 {
            var random = Walk(state: seed)
            var editor = Self.editor()
            editor.undoStack.removeAll() // the walk's own steps only, so undoing them all ends uncropped
            editor.hitTolerance = 6
            for step in 0 ..< 400 {
                let point = { Self.p(
                    Double(Int.random(in: -50 ... 1050, using: &random)),
                    Double(Int.random(in: -50 ... 550, using: &random))
                ) }
                let before = editor.document.crops
                switch Int.random(in: 0 ..< 10, using: &random) {
                case 0: editor.setTool(EditorTool.allCases.randomElement(using: &random) ?? .crop)
                case 1: editor.setTool(.crop)
                // Crop gestures only: other tools would edit the annotations themselves.
                case 2, 3: if editor.tool == .crop { Fixture.drag(&editor, [point(), point(), point()]) }
                case 4:
                    editor.beginGesture(at: point())
                    editor.updateGesture(to: point())
                    editor.cancelGesture()
                case 5: editor.undo()
                case 6: editor.redo()
                case 7: editor.restoreOriginal()
                case 8: editor.show(mediaId: ["m1", "m2", "v1"].randomElement(using: &random) ?? "m1")
                default:
                    if editor.tool == .crop { _ = editor.crop(to: CGRect(origin: point(), size: CGSize(width: 300, height: 200))) }
                }
                Self.checkInvariants(editor, "seed \(seed) step \(step)")
                if editor.currentMedia?.kind == .image, let id = editor.currentMediaId {
                    visited.insert([editor.showsOriginal, editor.document.crops[id] != nil, before != editor.document.crops])
                }
            }
            while editor.canUndo {
                editor.undo()
            }
            #expect(editor.document.crops.isEmpty, "seed \(seed)")
            #expect(Dictionary(uniqueKeysWithValues: editor.bundle.annotations.map { ($0.id, $0.shape) }) == Self.drawn, "seed \(seed)")
        }
        #expect(visited.count == 8, "every combination of tool, crop, and change was reached: \(visited)")
    }

    static func checkInvariants(_ editor: AnnotationEditor, _ context: String) {
        guard let item = editor.currentMedia else { return }
        #expect(item.kind == .video || item.kind == .image)
        #expect(editor.showsOriginal == (editor.tool == .crop), "\(context)")
        if editor.showsOriginal {
            #expect(editor.canvasFrame == original && editor.canvasOrigin == .zero, "\(context)")
            #expect(editor.cropOverlay != nil, "\(context)")
        } else {
            #expect(editor.canvasFrame == editor.currentFrame && editor.cropOverlay == nil, "\(context)")
        }
        for media in ["m1", "m2", "v1"] {
            let crop = editor.document.crops[media]
            let size = editor.media(media).map { PixelRect(x: 0, y: 0, width: $0.pixelWidth, height: $0.pixelHeight) }
            #expect(
                size == crop.map { PixelRect(x: 0, y: 0, width: $0.width, height: $0.height) } ?? editor.originalSize(of: media),
                "\(context)"
            )
            if let crop {
                #expect(crop != editor.originalSize(of: media), "\(context): a whole-image crop is stored as none")
                #expect(crop.x >= 0 && crop.y >= 0 && crop.x + crop.width <= 1000 && crop.y + crop.height <= 500, "\(context)")
                #expect(crop.width >= ImageCrop.minimumSide && crop.height >= ImageCrop.minimumSide, "\(context)")
                if media == "v1" { #expect(crop.width % 2 == 0 && crop.height % 2 == 0, "\(context): video crops are even") }
            }
            for annotation in editor.annotationsInOriginal(on: media) {
                #expect(annotation.shape == drawn[annotation.id], "\(context): \(annotation.id) drifted")
            }
        }
    }
}
