import CoreGraphics
import Foundation

// Pointer gestures. A gesture is begin → update* → end (commits one undo step) or cancel
// (restores the state from before begin). The crop and its gestures are in
// `AnnotationEditor+Crop.swift`. Spec: docs/06-annotation-editor.md §6.3–6.6.
public extension AnnotationEditor {
    /// Pointer down at `point` (media pixels) on the current media.
    /// While the Crop tool shows the original (`showsOriginal`), points are pixels of the original.
    mutating func beginGesture(at point: CGPoint) {
        cancelGesture()
        guard let item = currentMedia, let frame = canvasFrame else { return }
        // A canvas press hands ← / → back to the canvas (docs/06 §6.4).
        timelineTarget = nil
        let start = clamp(point, frame)
        drag.anchor = start
        drag.point = start
        message = nil
        switch tool {
        case .select:
            if let selected = selectedAnnotation, selected.mediaId == item.id, selected.isVisible(atMs: currentTimeMs),
               !isOutsideEdit(selected), let handle = handle(of: selected.shape, at: start, in: frame) {
                gestureBase = snapshot
                gesture = .resizing(annotationId: selected.id, handle: handle, origin: selected.shape)
            } else if let hit = hitTest(start) {
                select(hit.id)
                gestureBase = snapshot
                gesture = .moving(annotationId: hit.id, start: start, origin: hit.shape)
            } else {
                selection = nil
            }
        case .crop:
            beginCropGesture(item, at: start)
        case .rect, .freehand, .arrow, .insertion, .strike:
            gestureBase = snapshot
            gesture = .drawing(tool, points: [start])
        }
    }

    /// Pointer dragged to `point`. Moves and resizes show live; drawing and cropping preview.
    mutating func updateGesture(to point: CGPoint) {
        guard let gesture, let frame = canvasFrame else { return }
        let current = clamp(point, frame)
        drag.point = current
        let anchor = drag.anchor ?? current, modifiers = drag.modifiers
        let limits = CGSize(width: frame.width, height: frame.height)
        switch gesture {
        case let .drawing(tool, points):
            switch tool {
            case .freehand:
                guard let last = points.last, hypot(current.x - last.x, current.y - last.y) >= 1 else { return }
                self.gesture = .drawing(tool, points: points + [current])
            case .rect, .strike:
                // ⇧ a square, ⌥ from the center (HS2-Q5TA4C).
                let box = ModifiedBox.drawn(from: anchor, to: current, modifiers: modifiers, bounds: limits)
                self.gesture = .drawing(tool, points: [box.origin, CGPoint(x: box.maxX, y: box.maxY)])
            case .arrow:
                let end = modifiers.contains(.constrain) ? ModifiedBox.snapped(current, from: anchor, bounds: limits) : current
                self.gesture = .drawing(tool, points: [anchor, end])
            default:
                self.gesture = .drawing(tool, points: [points[0], current])
            }
        case let .moving(id, start, origin):
            let scale = Double(NormalizedSpace.max)
            var moveX = current.x - start.x, moveY = current.y - start.y
            // ⇧ keeps the move horizontal or vertical, whichever is larger (HS2-Q5TA4C).
            if modifiers.contains(.constrain) { if abs(moveX) >= abs(moveY) { moveY = 0 } else { moveX = 0 } }
            let dx = Int((moveX / frame.width * scale).rounded())
            let dy = Int((moveY / frame.height * scale).rounded())
            _ = document.bundle.update(id) { $0.shape = origin.translated(dx: dx, dy: dy) }
        case let .resizing(id, handle, origin):
            _ = document.bundle.update(id) {
                $0.shape = origin.resized(handle, to: current, in: frame, minimumSide: minimumSide, modifiers: modifiers)
            }
        case .cropping:
            let box = ModifiedBox.drawn(from: anchor, to: current, modifiers: modifiers, bounds: limits)
            self.gesture = .cropping(start: box.origin, current: CGPoint(x: box.maxX, y: box.maxY))
        case let .adjustingCrop(handle, start, origin, _):
            self.gesture = .adjustingCrop(
                handle,
                start: start,
                origin: origin,
                rect: adjustedCrop(origin, handle, from: start, to: current)
            )
        }
    }

    /// The modifier keys now held (`HS2-Q5TA4C`). During a drag, the last update is redone with
    /// them, so pressing or releasing ⇧ or ⌥ reshapes the drag without moving the pointer.
    mutating func setDragModifiers(_ modifiers: DragModifiers) {
        guard modifiers != drag.modifiers else { return }
        drag.modifiers = modifiers
        if gesture != nil, let point = drag.point { updateGesture(to: point) }
    }

    /// Pointer up: commits the gesture as one undo step.
    mutating func endGesture() {
        guard let gesture, let base = gestureBase else { return }
        self.gesture = nil
        gestureBase = nil
        switch gesture {
        case let .drawing(tool, points):
            guard let shape = drawnShape(tool, points: points) else {
                return // a click or tiny drag draws nothing
            }
            commitNewShape(shape, base: base)
        case .moving, .resizing:
            guard document != base.document else { return }
            pushUndo(base)
            redoStack.removeAll()
            coalesceKey = nil
        case let .cropping(start, current):
            let rect = CGRect(x: start.x, y: start.y, width: current.x - start.x, height: current.y - start.y).standardized
            // A click or a tiny drag (under the screen-point minimum) draws no new crop.
            guard max(rect.width, rect.height) >= minimumSide else { return }
            crop(to: rect)
        case let .adjustingCrop(_, _, origin, rect):
            guard rect != origin.cgRect else { return }
            crop(to: rect)
        }
    }

    /// Adds a finished shape as one undo step, selects it, and returns to the Select tool.
    private mutating func commitNewShape(_ shape: Shape, base: Snapshot) {
        let id = nextAnnotationID()
        pushUndo(base)
        redoStack.removeAll()
        coalesceKey = nil
        document.bundle.annotations.append(Annotation(id: id, mediaId: currentMediaId ?? "", shape: shape, note: ""))
        selection = id
        tool = .select
    }

    /// Keyboard drawing (Return with a drawing tool): adds a default-sized shape of the current
    /// tool centered on `center` (media pixels; default the media's center), kept inside the
    /// media. Like a drawn shape it is one undo step, selected, and the tool returns to Select,
    /// so the arrow keys move it and Return focuses its note. Spec: docs/06 §6.4.
    @discardableResult
    mutating func insertDefaultShape(at center: CGPoint? = nil) -> Bool {
        guard gesture == nil, let frame = currentFrame else { return false }
        switch tool {
        case .select:
            return false
        case .crop:
            message = "Drag to crop; keyboard cropping isn't available."
            return false
        default:
            break
        }
        // A fifth of the shorter side, so the shape is easy to see and to find with VoiceOver.
        let side = max(min(frame.width, frame.height) / 5, min(minimumSide * 2, frame.width, frame.height))
        let half = side / 2
        let wanted = center ?? CGPoint(x: frame.width / 2, y: frame.height / 2)
        let middle = CGPoint(
            x: min(max(wanted.x, half), frame.width - half),
            y: min(max(wanted.y, half), frame.height - half)
        )
        let box = CGRect(x: middle.x - half, y: middle.y - half, width: side, height: side)
        let shape: Shape
        switch tool {
        case .rect: shape = .rect(frame.norm(box))
        case .strike: shape = .strike(frame.norm(box))
        case .arrow: shape = .arrow(points: [frame.norm(CGPoint(x: box.minX, y: box.maxY)), frame.norm(CGPoint(x: box.maxX, y: box.minY))])
        case .insertion: shape = .insertion(frame.norm(middle))
        case .freehand:
            let points = (0 ..< 12).map { step -> NormPoint in
                let angle = Double(step) / 12 * 2 * .pi
                return frame.norm(CGPoint(x: middle.x + half * cos(angle), y: middle.y + half * sin(angle)))
            }
            shape = .freehand(points: points, closed: true)
        case .select, .crop: return false
        }
        commitNewShape(shape, base: snapshot)
        message = nil
        timelineTarget = nil
        return true
    }

    /// Esc: abandons the gesture and restores what was there before it began.
    mutating func cancelGesture() {
        cancelTimelineDrag()
        guard gesture != nil else { return }
        if let base = gestureBase {
            document = base.document
            selection = base.selection
        }
        gesture = nil
        gestureBase = nil
    }

    /// The shape being drawn, for the view to preview; nil when not drawing or still too small.
    var previewShape: Shape? {
        guard case let .drawing(tool, points) = gesture else { return nil }
        return drawnShape(tool, points: points)
    }

    /// The crop rectangle being drawn, moved, or resized, in pixels of the original.
    var previewCrop: CGRect? {
        switch gesture {
        case let .cropping(start, current):
            CGRect(x: start.x, y: start.y, width: current.x - start.x, height: current.y - start.y).standardized
        case let .adjustingCrop(_, _, _, rect):
            rect
        default:
            nil
        }
    }

    /// The topmost annotation on the current media under `point`. Among several hits, the one
    /// nearest its stroke wins, then the smallest, then the latest, so a box nested inside
    /// another stays selectable.
    func hitTest(_ point: CGPoint) -> Annotation? {
        guard let item = currentMedia else { return nil }
        let frame = MediaFrame(item)
        let candidates = annotations(on: item.id).enumerated().compactMap { index, annotation -> (Annotation, Double, Int)? in
            guard annotation.isVisible(atMs: currentTimeMs), !isOutsideEdit(annotation) else { return nil }
            return annotation.shape.hitDistance(point, in: frame, tolerance: hitTolerance).map { (annotation, $0, index) }
        }
        return candidates.min { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            let lhsArea = Geometry.area(lhs.0.shape.bounds), rhsArea = Geometry.area(rhs.0.shape.bounds)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            return lhs.2 > rhs.2
        }?.0
    }

    // MARK: Helpers

    /// " 2 annotations outside the crop are hidden.", or "" when none are. They stay in the
    /// draft; the inspector says they are left out when submitting.
    func outsideNote(_ mediaId: String, _ noun: String) -> String {
        switch outsideCount(on: mediaId) {
        case 0: ""
        case 1: " 1 annotation outside the \(noun) is hidden."
        case let count: " \(count) annotations outside the \(noun) are hidden."
        }
    }

    internal func clamp(_ point: CGPoint, _ frame: MediaFrame) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), frame.width), y: min(max(point.y, 0), frame.height))
    }

    internal func handle(of shape: Shape, at point: CGPoint, in frame: MediaFrame) -> ShapeHandle? {
        shape.handles(in: frame)
            .map { ($0.handle, hypot($0.position.x - point.x, $0.position.y - point.y)) }
            .filter { $0.1 <= hitTolerance }
            .min { $0.1 < $1.1 }?.0
    }

    /// The shape a drawing gesture makes, or nil while it is too small to keep.
    internal func drawnShape(_ tool: EditorTool, points: [CGPoint]) -> Shape? {
        guard let frame = currentFrame, let first = points.first, let last = points.last else { return nil }
        let side = min(minimumSide, frame.width, frame.height)
        switch tool {
        case .rect, .strike:
            let rect = CGRect(x: first.x, y: first.y, width: last.x - first.x, height: last.y - first.y).standardized
            guard rect.width >= side, rect.height >= side else { return nil }
            return tool == .rect ? .rect(frame.norm(rect)) : .strike(frame.norm(rect))
        case .arrow:
            guard hypot(last.x - first.x, last.y - first.y) >= side * 2 else { return nil }
            return .arrow(points: [frame.norm(first), frame.norm(last)])
        case .insertion:
            return .insertion(frame.norm(last))
        case .freehand:
            // Jitter removed, faithful to the stroke: samples 3 screen points apart, nothing moved
            // more than 1.5 (`minimumSide` is 6 screen points in media pixels).
            let smoothed = FreehandSmoothing.smooth(points, closed: false, spacing: minimumSide / 2, tolerance: minimumSide / 4)
            var normalized: [NormPoint] = []
            for point in smoothed.map(frame.norm) where normalized.last != point {
                normalized.append(point)
            }
            let box = CGRect(
                x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0,
                width: (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0),
                height: (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
            )
            guard normalized.count >= 3, max(box.width, box.height) >= side else { return nil }
            return .freehand(points: normalized, closed: true)
        case .select, .crop:
            return nil
        }
    }
}

extension ReviewBundle {
    mutating func resize(_ mediaId: String, width: Int, height: Int) {
        guard let index = media.firstIndex(where: { $0.id == mediaId }) else { return }
        media[index].pixelWidth = width
        media[index].pixelHeight = height
    }
}
