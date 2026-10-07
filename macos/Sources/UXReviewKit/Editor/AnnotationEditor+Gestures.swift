import CoreGraphics
import Foundation

// Pointer gestures and cropping. A gesture is begin → update* → end (commits one undo step)
// or cancel (restores the state from before begin). Spec: docs/06-annotation-editor.md §6.3–6.6.
public extension AnnotationEditor {
    /// Pointer down at `point` (media pixels) on the current media.
    mutating func beginGesture(at point: CGPoint) {
        cancelGesture()
        guard let item = currentMedia else { return }
        let frame = MediaFrame(item)
        let start = clamp(point, frame)
        message = nil
        switch tool {
        case .select:
            if let selected = selectedAnnotation, selected.mediaId == item.id, selected.isVisible(atMs: currentTimeMs),
               let handle = handle(of: selected.shape, at: start, in: frame) {
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
            guard item.kind == .image else {
                message = "Videos can't be cropped."
                return
            }
            gestureBase = snapshot
            gesture = .cropping(start: start, current: start)
        case .rect, .freehand, .arrow, .insertion, .strike:
            gestureBase = snapshot
            gesture = .drawing(tool, points: [start])
        }
    }

    /// Pointer dragged to `point`. Moves and resizes show live; drawing and cropping preview.
    mutating func updateGesture(to point: CGPoint) {
        guard let gesture, let frame = currentFrame else { return }
        let current = clamp(point, frame)
        switch gesture {
        case let .drawing(tool, points):
            if tool == .freehand {
                guard let last = points.last, hypot(current.x - last.x, current.y - last.y) >= 1 else { return }
                self.gesture = .drawing(tool, points: points + [current])
            } else {
                self.gesture = .drawing(tool, points: [points[0], current])
            }
        case let .moving(id, start, origin):
            let scale = Double(NormalizedSpace.max)
            let dx = Int(((current.x - start.x) / frame.width * scale).rounded())
            let dy = Int(((current.y - start.y) / frame.height * scale).rounded())
            _ = document.bundle.update(id) { $0.shape = origin.translated(dx: dx, dy: dy) }
        case let .resizing(id, handle, origin):
            _ = document.bundle.update(id) { $0.shape = origin.resized(handle, to: current, in: frame, minimumSide: minimumSide) }
        case let .cropping(start, _):
            self.gesture = .cropping(start: start, current: current)
        }
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
            crop(to: CGRect(x: start.x, y: start.y, width: current.x - start.x, height: current.y - start.y).standardized)
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
        return true
    }

    /// Esc: abandons the gesture and restores what was there before it began.
    mutating func cancelGesture() {
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

    /// The crop rectangle being dragged, in media pixels.
    var previewCrop: CGRect? {
        guard case let .cropping(start, current) = gesture else { return nil }
        return CGRect(x: start.x, y: start.y, width: current.x - start.x, height: current.y - start.y).standardized
    }

    /// The topmost annotation on the current media under `point`. Among several hits, the one
    /// nearest its stroke wins, then the smallest, then the latest, so a box nested inside
    /// another stays selectable.
    func hitTest(_ point: CGPoint) -> Annotation? {
        guard let item = currentMedia else { return nil }
        let frame = MediaFrame(item)
        let candidates = annotations(on: item.id).enumerated().compactMap { index, annotation -> (Annotation, Double, Int)? in
            guard annotation.isVisible(atMs: currentTimeMs) else { return nil }
            return annotation.shape.hitDistance(point, in: frame, tolerance: hitTolerance).map { (annotation, $0, index) }
        }
        return candidates.min { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            let lhsArea = Geometry.area(lhs.0.shape.bounds), rhsArea = Geometry.area(rhs.0.shape.bounds)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            return lhs.2 > rhs.2
        }?.0
    }

    // MARK: Crop

    /// Crops the current image to `rect` (media pixels, snapped outward to whole pixels).
    /// Annotations move with the image; those left entirely outside are removed (undo brings
    /// them back). Returns false, with a message, when the crop is refused.
    @discardableResult
    mutating func crop(to rect: CGRect) -> Bool {
        guard let item = currentMedia else { return false }
        guard item.kind == .image else {
            message = "Videos can't be cropped."
            return false
        }
        guard let pixels = PixelRect.snapping(rect, width: item.pixelWidth, height: item.pixelHeight),
              pixels.width >= ImageCrop.minimumSide, pixels.height >= ImageCrop.minimumSide
        else {
            message = "A crop must be at least \(ImageCrop.minimumSide) × \(ImageCrop.minimumSide) pixels."
            return false
        }
        guard pixels != Self.size(of: item) else { return false }
        let frame = MediaFrame(item)
        var removed = 0
        let changed = perform { snapshot in
            let previous = snapshot.document.crops[item.id] ?? Self.size(of: item)
            snapshot.document.crops[item.id] = PixelRect(
                x: previous.x + pixels.x, y: previous.y + pixels.y, width: pixels.width, height: pixels.height
            )
            snapshot.document.bundle.resize(item.id, width: pixels.width, height: pixels.height)
            snapshot.document.bundle.annotations = snapshot.document.bundle.annotations.compactMap { annotation in
                guard annotation.mediaId == item.id else { return annotation }
                guard let shape = ImageCrop.transform(annotation.shape, from: frame, crop: pixels) else {
                    removed += 1
                    return nil
                }
                var moved = annotation
                moved.shape = shape
                return moved
            }
            if let selected = snapshot.selection, !snapshot.document.bundle.annotations.contains(where: { $0.id == selected }) {
                snapshot.selection = nil
            }
            return true
        }
        guard changed else { return false }
        message = "Cropped to \(pixels.width) × \(pixels.height) px."
            + (removed > 0 ? " Removed \(removed) annotation\(removed == 1 ? "" : "s") outside the crop." : "")
        tool = .select
        return true
    }

    /// Restores the current image's size from when the session opened, mapping annotations back
    /// onto it. Undoable.
    @discardableResult
    mutating func resetCrop() -> Bool {
        guard let item = currentMedia, let crop = document.crops[item.id], let original = originalSizes[item.id] else { return false }
        let frame = MediaFrame(item)
        let full = MediaFrame(width: Double(original.width), height: Double(original.height))
        return perform { snapshot in
            snapshot.document.crops[item.id] = nil
            snapshot.document.bundle.resize(item.id, width: original.width, height: original.height)
            for index in snapshot.document.bundle.annotations.indices where snapshot.document.bundle.annotations[index].mediaId == item.id {
                snapshot.document.bundle.annotations[index].shape = snapshot.document.bundle.annotations[index].shape.mapPoints { point in
                    let pixel = frame.pixel(point)
                    return full.norm(CGPoint(x: pixel.x + Double(crop.x), y: pixel.y + Double(crop.y)))
                }
            }
            return true
        }
    }

    // MARK: Helpers

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
            var normalized: [NormPoint] = []
            for point in points.map(frame.norm) where normalized.last != point {
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
