import AppKit
import UXReviewKit

/// The canvas cursor. Most of the time one cursor rect covers the canvas: an arrow (Select), a
/// crosshair (drawing tools), or an open / closed hand while Space pans. The Crop tool tracks the
/// pointer instead (`HS2-9RRP8G`, docs/06 §6.6): resize cursors on the crop rectangle's edges and
/// corners, an open hand inside a crop (closed while moving it), and a crosshair elsewhere. The
/// rules are `AnnotationEditor.canvasCursor`, hit-tested exactly as a press is (`cropHandle`), so
/// overlapping edge zones on a small crop show the handle a press would grab. Cursor rects can't
/// express that, so a tracking area (mouse moved + cursor update) sets the cursor, and every model
/// change (a crop moved or zoomed under a still pointer) re-evaluates it through
/// `resetCursorRects`.
extension AnnotationCanvasView {
    /// The press and hover hit tolerance, in screen points (divided by the zoom for pixels).
    static let hitTolerance: CGFloat = 7

    /// True while the Crop tool sets the cursor from the pointer instead of a cursor rect.
    var tracksCropCursor: Bool { model?.editor.showsOriginal == true && !spaceHeld }

    /// The cursor rect's cursor: the pan hands while Space is held, else the tool's.
    private var rectCursor: NSCursor? {
        guard let model else { return nil }
        if spaceHeld { return panAnchor == nil ? .openHand : .closedHand }
        return Self.cursor(model.editor.canvasCursor(at: nil, tolerance: 0))
    }

    override func resetCursorRects() {
        if tracksCropCursor {
            updateCropCursor()
        } else if let rectCursor {
            addCursorRect(bounds, cursor: rectCursor)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !trackingAreas.contains(where: { $0.owner === self && $0.options.contains(.cursorUpdate) }) else { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCropCursor()
    }

    /// Agrees with the cursor rect outside the Crop tool, so the two never fight.
    override func cursorUpdate(with _: NSEvent) {
        if tracksCropCursor { updateCropCursor() } else { rectCursor?.set() }
    }

    /// Sets the Crop tool's cursor for where the pointer is now; nothing with other tools, or
    /// when the pointer is off the canvas outside a gesture.
    func updateCropCursor() {
        guard tracksCropCursor, let model, let window, let renderer = renderer() else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) || model.editor.gesture != nil else { return }
        let cursor = model.editor.canvasCursor(at: renderer.pixel(point), tolerance: Self.hitTolerance / renderer.scale)
        Self.cursor(cursor).set()
    }

    static func cursor(_ cursor: CanvasCursor) -> NSCursor {
        switch cursor {
        case .arrow: .arrow
        case .crosshair: .crosshair
        case .openHand: .openHand
        case .closedHand: .closedHand
        case let .resize(handle): .frameResize(position: position(handle), directions: .all)
        }
    }

    /// The canvas is flipped like the media, so a handle's name is where it is on screen.
    static func position(_ handle: BoxHandle) -> NSCursor.FrameResizePosition {
        switch handle {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
    }
}
