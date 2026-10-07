import AppKit
import SwiftUI
import UXReviewKit

/// The editor's drawing surface: shows the current media, fitted or zoomed (`CanvasViewport`),
/// and turns mouse, trackpad, and keyboard input into `AnnotationEditor` and zoom calls. Drawing
/// goes through `AnnotationRenderer`, the same code the previews and `--annotate --render-dir`
/// use. Spec: docs/06-annotation-editor.md §6.2–6.5.
final class AnnotationCanvasView: NSView {
    var model: EditorModel? {
        didSet { needsDisplay = true }
    }

    static let strokeWidth: CGFloat = 2.5

    /// Space is held: dragging pans instead of drawing.
    private var spaceHeld = false
    /// The last pointer location of a pan drag (space-drag or middle-button drag).
    private var panAnchor: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    /// Where the media is drawn: fitted (never upscaled past 2×) or as zoomed and panned.
    func renderer() -> AnnotationRenderer? {
        guard let model, let item = model.editor.currentMedia, let layout = model.layout(in: bounds.size) else { return nil }
        return AnnotationRenderer(frame: MediaFrame(item), imageRect: layout.imageRect, lineWidth: Self.strokeWidth)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportSize()
    }

    private func reportSize() {
        model?.canvasDidResize(bounds.size, backingScale: window?.backingScaleFactor ?? 2)
    }

    // MARK: Drawing

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // A zoomed image extends past the canvas; views no longer clip by default (macOS 14).
        clipsToBounds = true
        context.clip(to: bounds)
        context.setFillColor(CGColor(gray: 0.13, alpha: 1))
        context.fill(bounds)
        reportSize()
        guard let model, let item = model.editor.currentMedia, let renderer = renderer() else {
            drawPlaceholder(
                "No captures in this review yet.\nAdd Media… (⌘O), drop images or movies here, or capture from the menu bar."
            )
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            // The canvas is always dark, whatever the appearance.
            .foregroundColor: NSColor(white: 0.72, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    }

    // MARK: Cursor

    override func resetCursorRects() {
        guard let model else { return }
        if spaceHeld {
            addCursorRect(bounds, cursor: panAnchor == nil ? .openHand : .closedHand)
        } else {
            addCursorRect(bounds, cursor: model.editor.tool == .select ? .arrow : .crosshair)
        }
    }

    // MARK: Zoom and pan

    private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// Pinch to zoom about the pointer.
    override func magnify(with event: NSEvent) {
        let anchor = location(event)
        model?.zoom { $0.magnify(by: 1 + event.magnification, anchor: anchor, view: $1, media: $2, backingScale: $3) }
    }

    /// Two-finger double tap: toggle between fit and actual pixels at the pointer.
    override func smartMagnify(with event: NSEvent) {
        guard let model else { return }
        if model.viewport.isFit {
            let anchor = location(event)
            model.zoom { $0.zoom(to: 1 / $3, anchor: anchor, view: $1, media: $2, backingScale: $3) }
        } else {
            model.zoomToFit()
        }
    }

    /// Scrolling pans a zoomed image; ⌘-scroll (or a mouse wheel with ⌘) zooms about the pointer.
    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
            let anchor = location(event)
            model.zoom { $0.magnify(by: exp(delta), anchor: anchor, view: $1, media: $2, backingScale: $3) }
        } else {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10 // wheel "lines" to points
            let delta = CGVector(dx: event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale)
            model.zoom { viewport, view, media, _ in viewport.pan(by: delta, view: view, media: media) }
        }
    }

    private func beginPan(_ event: NSEvent) {
        panAnchor = location(event)
        window?.invalidateCursorRects(for: self)
    }

    private func continuePan(_ event: NSEvent) {
        guard let model, let last = panAnchor else { return }
        let point = location(event)
        panAnchor = point
        let delta = CGVector(dx: point.x - last.x, dy: point.y - last.y)
        model.zoom { viewport, view, media, _ in viewport.pan(by: delta, view: view, media: media) }
    }

    private func endPan() {
        panAnchor = nil
        window?.invalidateCursorRects(for: self)
    }

    override func otherMouseDown(with event: NSEvent) { beginPan(event) }
    override func otherMouseDragged(with event: NSEvent) { continuePan(event) }
    override func otherMouseUp(with _: NSEvent) { endPan() }

    /// ⌘+ (or ⌘=), ⌘-, ⌘0 (fit), ⌘1 (actual pixels), whichever control in the window has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let model, window?.isKeyWindow == true,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift) == .command
        else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "=", "+": model.zoomIn()
        case "-": model.zoomOut()
        case "0": model.zoomToFit()
        case "1": model.zoomToActualPixels()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: Mouse

    private func mediaPoint(_ event: NSEvent) -> CGPoint? {
        guard let renderer = renderer() else { return nil }
        return renderer.pixel(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if spaceHeld { return beginPan(event) }
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
        if panAnchor != nil { return continuePan(event) }
        guard let model, let point = mediaPoint(event) else { return }
        model.mutate { $0.updateGesture(to: point) }
        autoScroller.track(convert(event.locationInWindow, from: nil), model: model)
    }

    /// Pans near the edges while a gesture runs (docs/06 §6.2.1).
    private let autoScroller = CanvasAutoScroller()

    override func mouseUp(with event: NSEvent) {
        autoScroller.stop()
        if panAnchor != nil { return endPan() }
        guard let model else { return }
        if let point = mediaPoint(event) {
            model.mutate { $0.updateGesture(to: point) }
        }
        model.mutate { $0.endGesture() }
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        if holdSpace(event) { return }
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
        case .home?, .end?: model.mutate { $0.setCurrentTime(event.specialKey == .home ? 0 : Int.max) }
        case .tab?, .backTab?:
            model.mutate { $0.selectNext(forward: !shift && event.specialKey != .backTab) }
        case .carriageReturn?, .enter?:
            pressReturn()
        default:
            if event.keyCode == 53 { // Esc: cancel the gesture, else the tool, else the selection
                model.mutate { editor in
                    if editor.gesture != nil || editor.timelineDrag != nil {
                        editor.cancelGesture()
                    } else if editor.tool != .select {
                        editor.setTool(.select)
                    } else {
                        editor.select(nil)
                    }
                }
            } else if command || !handleCharacter(event.charactersIgnoringModifiers?.first, shift: shift) {
                super.keyDown(with: event)
                return
            }
        }
        window?.invalidateCursorRects(for: self)
    }

    /// `,` / `.` step the playhead (Shift: 1 s; on a US layout Shift turns them into `<` / `>`);
    /// K plays or pauses a video; letters choose tools. False when the character means nothing here.
    private func handleCharacter(_ character: Character?, shift: Bool) -> Bool {
        guard let model, let character else { return false }
        if ",.<>".contains(character) {
            model.mutate { $0.stepTime(forward: character == "." || character == ">", large: shift) }
            return true
        }
        if character == "k" || character == "K" {
            guard model.editor.currentDurationMs != nil else { return false }
            model.togglePlayback()
            return true
        }
        guard let tool = EditorTool.forShortcut(character) else { return false }
        model.mutate { $0.setTool(tool) }
        return true
    }

    /// Return: with a drawing tool, a default shape at the middle of what is visible; with
    /// Select, focus the selected annotation's note (docs/06 §6.4).
    private func pressReturn() {
        guard let model else { return }
        guard model.editor.tool != .select else {
            if model.editor.selection != nil { model.focusNoteRequest += 1 }
            return
        }
        let center = renderer()?.pixel(CGPoint(x: bounds.midX, y: bounds.midY))
        model.mutate { _ = $0.insertDefaultShape(at: center) }
        if let id = model.editor.selection, let element = accessibilityElements[id] {
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        }
    }

    // MARK: Accessibility

    /// One element per annotation on the current capture, kept by id so VoiceOver's focus survives redraws.
    private var accessibilityElements: [String: AnnotationAccessibilityElement] = [:]

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        guard let item = model?.editor.currentMedia else { return "Annotation canvas, no capture" }
        let count = model?.editor.visibleAnnotations(on: item.id).count ?? 0
        let time = model?.editor.currentDurationMs.map { _ in " showing at \(TimeFormat.clock(model?.editor.currentTimeMs ?? 0))" } ?? ""
        return "Annotation canvas, \(item.filename), \(count) annotation\(count == 1 ? "" : "s")\(time)"
    }

    override func accessibilityHelp() -> String? {
        "Choose a tool with V, R, F, A, I, or S, then press Return to add a shape. "
            + "Arrow keys move the selected annotation, Tab selects the next one, and Return edits its note. "
            + "On a video, K plays and pauses, comma and period step the playhead, and Home and End jump to the start and end."
    }

    override func accessibilityChildren() -> [Any]? {
        guard let model, let item = model.editor.currentMedia, let renderer = renderer() else { return [] }
        let frame = MediaFrame(item)
        var live: [String: AnnotationAccessibilityElement] = [:]
        let elements = model.editor.visibleAnnotations(on: item.id).map { annotation -> AnnotationAccessibilityElement in
            let element = accessibilityElements[annotation.id] ?? AnnotationAccessibilityElement(annotationID: annotation.id, canvas: self)
            element.setAccessibilityLabel(model.editor.accessibilityLabel(for: annotation.id))
            // Points and thin shapes get a minimum target so VoiceOver can outline them.
            let rect = renderer.rect(frame.pixel(annotation.shape.bounds)).insetBy(dx: -8, dy: -8)
            element.setAccessibilityFrameInParentSpace(rect.intersection(bounds))
            element.setAccessibilitySelected(model.editor.selection == annotation.id)
            live[annotation.id] = element
            return element
        }
        accessibilityElements = live
        return elements
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        guard let id = model?.editor.selection, let element = accessibilityElements[id] else { return [] }
        return [element]
    }

    func announceChanges() {
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// Space (outside a gesture) turns dragging into panning until it is released.
    private func holdSpace(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers == " ", model?.editor.gesture == nil else { return false }
        if !spaceHeld {
            spaceHeld = true
            window?.invalidateCursorRects(for: self)
        }
        return true
    }

    override func keyUp(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " " else { return super.keyUp(with: event) }
        spaceHeld = false
        endPan()
    }

    override func resignFirstResponder() -> Bool {
        spaceHeld = false
        panAnchor = nil
        return super.resignFirstResponder()
    }
}

extension AnnotationCanvasView {
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
}

/// An annotation on the canvas for VoiceOver: its label reads number, shape, intents, and note;
/// pressing it (VO-Space) selects it, after which the arrow keys move it.
final class AnnotationAccessibilityElement: NSAccessibilityElement {
    let annotationID: String
    private let onPress: @MainActor @Sendable () -> Bool

    @MainActor
    init(annotationID: String, canvas: AnnotationCanvasView) {
        self.annotationID = annotationID
        onPress = { [weak canvas] in
            guard let canvas, let model = canvas.model else { return false }
            model.mutate { $0.select(annotationID) }
            canvas.window?.makeFirstResponder(canvas)
            return true
        }
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityRoleDescription("annotation")
        setAccessibilityParent(canvas)
    }

    override func accessibilityPerformPress() -> Bool {
        let press = onPress
        return MainActor.assumeIsolated { press() }
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
        view.announceChanges()
    }
}
