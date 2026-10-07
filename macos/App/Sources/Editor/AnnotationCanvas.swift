import AppKit
import SwiftUI
import UXReviewKit

/// The editor's drawing surface: shows the current media fitted to the view and turns mouse and
/// keyboard input into `AnnotationEditor` calls. Drawing goes through `AnnotationRenderer`, the
/// same code the previews and `--annotate --render-dir` use. Spec: docs/06-annotation-editor.md §6.2–6.5.
final class AnnotationCanvasView: NSView {
    var model: EditorModel? {
        didSet { needsDisplay = true }
    }

    static let padding: CGFloat = 28
    static let strokeWidth: CGFloat = 2.5

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    /// Where the media is drawn: aspect-fit inside the padded bounds, never upscaled past 2×.
    func renderer() -> AnnotationRenderer? {
        guard let model, let item = model.editor.currentMedia else { return nil }
        let frame = MediaFrame(item)
        let available = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        guard available.width > 0, available.height > 0 else { return nil }
        let scale = min(available.width / frame.width, available.height / frame.height, 2)
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        let origin = CGPoint(x: available.midX - size.width / 2, y: available.midY - size.height / 2)
        return AnnotationRenderer(frame: frame, imageRect: CGRect(origin: origin, size: size), lineWidth: Self.strokeWidth)
    }

    // MARK: Drawing

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(CGColor(gray: 0.13, alpha: 1))
        context.fill(bounds)
        guard let model, let item = model.editor.currentMedia, let renderer = renderer() else {
            drawPlaceholder("No captures in this review yet.")
            return
        }
        let imageRect = renderer.imageRect
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: CGColor(gray: 0, alpha: 0.5))
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(imageRect)
        context.restoreGState()
        if let image = model.image(item.id) {
            context.saveGState()
            context.interpolationQuality = .high
            // Images draw bottom-up; flip locally inside the flipped view.
            context.translateBy(x: 0, y: imageRect.minY + imageRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: imageRect)
            context.restoreGState()
        } else {
            drawPlaceholder("\(item.filename) can't be read.")
        }
        let items = model.session.renderItems(item.id)
        renderer.draw(
            items,
            selection: model.editor.selection,
            preview: model.editor.previewShape,
            crop: model.editor.previewCrop,
            in: context
        )
    }

    private func drawPlaceholder(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    // MARK: Cursor

    override func resetCursorRects() {
        guard let model else { return }
        addCursorRect(bounds, cursor: model.editor.tool == .select ? .arrow : .crosshair)
    }

    // MARK: Mouse

    private func mediaPoint(_ event: NSEvent) -> CGPoint? {
        guard let renderer = renderer() else { return nil }
        return renderer.pixel(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model, let point = mediaPoint(event), let scale = renderer()?.scale else { return }
        model.mutate { editor in
            // Sizes are in screen points, so the feel is the same at every zoom.
            editor.minimumSide = 6 / scale
            editor.hitTolerance = 7 / scale
            editor.beginGesture(at: point)
        }
        if event.clickCount == 2, model.editor.selection != nil {
            model.focusNoteRequest += 1
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let point = mediaPoint(event) else { return }
        model.mutate { $0.updateGesture(to: point) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        if let point = mediaPoint(event) {
            model.mutate { $0.updateGesture(to: point) }
        }
        model.mutate { $0.endGesture() }
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Edit menu (the canvas is first responder; text fields keep their own undo)

    @objc func undo(_: Any?) { model?.mutate { $0.undo() } }
    @objc func redo(_: Any?) { model?.mutate { $0.redo() } }
    @objc func duplicate(_: Any?) { model?.mutate { _ = $0.duplicateSelection() } }
    @objc func saveDocument(_: Any?) { model?.save() }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let editor = model?.editor else { return false }
        switch item.action {
        case #selector(undo(_:)): return editor.canUndo
        case #selector(redo(_:)): return editor.canRedo
        case #selector(duplicate(_:)): return editor.selection != nil
        default: return true
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        let step: Double = shift ? 10 : 1
        let command = event.modifierFlags.contains(.command)
        switch event.specialKey {
        case .delete?, .deleteForward?, .backspace?:
            model.mutate { _ = $0.deleteSelection() }
        case .leftArrow?: model.mutate { _ = $0.nudgeSelection(dx: -step, dy: 0) }
        case .rightArrow?: model.mutate { _ = $0.nudgeSelection(dx: step, dy: 0) }
        case .upArrow?: model.mutate { _ = $0.nudgeSelection(dx: 0, dy: -step) }
        case .downArrow?: model.mutate { _ = $0.nudgeSelection(dx: 0, dy: step) }
        case .tab?, .backTab?:
            model.mutate { $0.selectNext(forward: !shift && event.specialKey != .backTab) }
        case .carriageReturn?, .enter?:
            if model.editor.selection != nil { model.focusNoteRequest += 1 }
        default:
            if event.keyCode == 53 { // Esc: cancel the gesture, else the tool, else the selection
                model.mutate { editor in
                    if editor.gesture != nil {
                        editor.cancelGesture()
                    } else if editor.tool != .select {
                        editor.setTool(.select)
                    } else {
                        editor.select(nil)
                    }
                }
            } else if !command, let character = event.charactersIgnoringModifiers?.first, let tool = EditorTool.forShortcut(character) {
                model.mutate { $0.setTool(tool) }
            } else {
                super.keyDown(with: event)
                return
            }
        }
        window?.invalidateCursorRects(for: self)
    }
}

/// SwiftUI wrapper; redraws whenever the model's revision changes.
struct AnnotationCanvas: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeNSView(context _: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView()
        view.model = model
        return view
    }

    func updateNSView(_ view: AnnotationCanvasView, context _: Context) {
        _ = model.revision
        view.model = model
        view.window?.invalidateCursorRects(for: view)
    }
}
