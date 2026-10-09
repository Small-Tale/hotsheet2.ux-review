import CoreGraphics
import Foundation

// The crop (`HS2-4N722Z`; videos `HS2-M03YP2`). Each capture, image or video, has at most one
// crop, relative to its original (the file as captured); a new or adjusted crop replaces it, and
// crops never compose. Video crops have even sides (H.264). While the Crop tool
// is chosen the canvas shows the original with the crop rectangle on it (`showsOriginal`); with
// any other tool it shows the cropped media, and everything (fit, zoom, hit testing, drawing)
// works in the cropped frame. Spec: docs/06-annotation-editor.md §6.6.
public extension AnnotationEditor {
    // MARK: Canvas space

    /// True while the Crop tool shows the current media (image or video) uncropped, with its
    /// crop rectangle.
    var showsOriginal: Bool { tool == .crop && currentMedia != nil }

    /// The size of `mediaId`'s original, which crops are relative to.
    func originalSize(of mediaId: String) -> PixelRect? {
        originalSizes[mediaId] ?? media(mediaId).map(Self.size(of:))
    }

    /// The part of `mediaId`'s original that is kept: its crop, or the whole original.
    func cropRect(of mediaId: String) -> PixelRect? {
        document.crops[mediaId] ?? originalSize(of: mediaId)
    }

    /// The frame the canvas lays out, draws, and takes points in: the original while the Crop
    /// tool shows it, else the current media as cropped.
    var canvasFrame: MediaFrame? {
        guard showsOriginal, let id = currentMediaId, let size = originalSize(of: id) else { return currentFrame }
        return MediaFrame(width: Double(size.width), height: Double(size.height))
    }

    /// Where the canvas's pixel (0, 0) lies in the current media's original: the crop's origin,
    /// or zero while the original shows. The view keeps the same content in place when it changes.
    var canvasOrigin: CGPoint {
        guard !showsOriginal, let id = currentMediaId, let crop = document.crops[id] else { return .zero }
        return CGPoint(x: crop.x, y: crop.y)
    }

    /// The crop rectangle the canvas draws while the Crop tool shows the original (pixels of the
    /// original): the one being drawn or adjusted, else the current crop (the whole original when
    /// uncropped). Nil with other tools.
    var cropOverlay: CGRect? {
        guard showsOriginal, let id = currentMediaId else { return nil }
        return previewCrop ?? cropRect(of: id)?.cgRect
    }

    /// The annotations the canvas draws while the Crop tool shows the original: those showing at
    /// the playhead, mapped exactly into the original's space, including those outside the crop
    /// (the dimmed overlay covers them). They can't be selected or edited there.
    func annotationsInOriginal(on mediaId: String) -> [Annotation] {
        let time = mediaId == currentMediaId ? currentTimeMs : 0
        let crop = document.crops[mediaId]
        let size = originalSize(of: mediaId)
        return annotations(on: mediaId).filter { $0.isVisible(atMs: time) }.map { annotation in
            guard let crop, let size else { return annotation }
            var mapped = annotation
            mapped.shape = EditProjection.shape(annotation.shape, outOf: crop, to: size)
            return mapped
        }
    }

    // MARK: Crop gestures

    /// A Crop tool press at `start` (pixels of the original): on an edge or corner of the crop
    /// rectangle it resizes, inside a crop it moves, elsewhere it draws a new rectangle.
    internal mutating func beginCropGesture(_ item: MediaItem, at start: CGPoint) {
        gestureBase = snapshot
        if let crop = cropRect(of: item.id), let handle = cropHandle(at: start) {
            gesture = .adjustingCrop(handle, start: start, origin: crop, rect: crop.cgRect)
        } else {
            gesture = .cropping(start: start, current: start)
        }
    }

    /// What a Crop tool press at `point` (pixels of the original) grabs: an edge or corner within
    /// the hit tolerance (`hitTolerance` unless given), the inside of an existing crop, or nil (a
    /// new rectangle). The canvas cursor uses the same test (`canvasCursor`).
    func cropHandle(at point: CGPoint, tolerance: Double? = nil) -> CropHandle? {
        guard let id = currentMediaId, let crop = cropRect(of: id) else { return nil }
        let rect = crop.cgRect
        let tolerance = tolerance ?? hitTolerance
        let alongX = point.x >= rect.minX - tolerance && point.x <= rect.maxX + tolerance
        let alongY = point.y >= rect.minY - tolerance && point.y <= rect.maxY + tolerance
        // On a small crop both edges can be in reach; the nearer one wins.
        let left = alongY && abs(point.x - rect.minX) <= tolerance && abs(point.x - rect.minX) <= abs(point.x - rect.maxX)
        let right = alongY && !left && abs(point.x - rect.maxX) <= tolerance
        let top = alongX && abs(point.y - rect.minY) <= tolerance && abs(point.y - rect.minY) <= abs(point.y - rect.maxY)
        let bottom = alongX && !top && abs(point.y - rect.maxY) <= tolerance
        let box: BoxHandle? = switch (left, right, top, bottom) {
        case (true, _, true, _): .topLeft
        case (_, true, true, _): .topRight
        case (true, _, _, true): .bottomLeft
        case (_, true, _, true): .bottomRight
        case (true, _, _, _): .left
        case (_, true, _, _): .right
        case (_, _, true, _): .top
        case (_, _, _, true): .bottom
        default: nil
        }
        if let box { return .edge(box) }
        return document.crops[id] != nil && rect.contains(point) ? .move : nil
    }

    /// The crop rectangle after dragging `handle` from `start` to `point`: moved by whole pixels
    /// and kept inside the original, or resized (never flipped, never under the minimum side).
    internal func adjustedCrop(_ origin: PixelRect, _ handle: CropHandle, from start: CGPoint, to point: CGPoint) -> CGRect {
        guard let id = currentMediaId, let size = originalSize(of: id) else { return origin.cgRect }
        switch handle {
        case .move:
            let x = min(max(origin.x + Int((point.x - start.x).rounded()), 0), size.width - origin.width)
            let y = min(max(origin.y + Int((point.y - start.y).rounded()), 0), size.height - origin.height)
            return CGRect(x: x, y: y, width: origin.width, height: origin.height)
        case let .edge(box):
            // ⇧ keeps the crop's aspect ratio, ⌥ resizes it about its center (HS2-Q5TA4C).
            return ModifiedBox.resize(
                origin.cgRect, box, to: point, modifiers: dragModifiers,
                within: BoxLimits(bounds: CGSize(width: size.width, height: size.height), minimumSide: Double(ImageCrop.minimumSide))
            )
        }
    }

    // MARK: Cropping

    /// Sets the current media's crop to `rect` (pixels of the original, snapped outward to whole
    /// pixels and clipped to it), replacing any earlier crop: one undo step. A rectangle covering
    /// the whole original removes the crop. Annotations move with the media exactly; those left
    /// outside are hidden, not removed, and come back when the crop is widened or restored. The
    /// file itself is cropped only when the review is submitted (`HS2-71SSJG`). A video's crop is
    /// then widened to even sides (`PixelRect.evened`), so the filed movie is exactly its size. The
    /// tool stays as it is. Returns false, with a message, when the crop is refused.
    @discardableResult
    mutating func crop(to rect: CGRect) -> Bool {
        guard let item = currentMedia, let original = originalSize(of: item.id),
              var pixels = PixelRect.snapping(rect, width: original.width, height: original.height)
        else {
            message = "A crop must be at least \(ImageCrop.minimumSide) × \(ImageCrop.minimumSide) pixels."
            return false
        }
        if item.kind == .video { pixels = pixels.evened(within: original) }
        guard pixels.width >= ImageCrop.minimumSide, pixels.height >= ImageCrop.minimumSide
        else {
            message = "A crop must be at least \(ImageCrop.minimumSide) × \(ImageCrop.minimumSide) pixels."
            return false
        }
        let previous = document.crops[item.id]
        let next: PixelRect? = pixels == original ? nil : pixels
        guard next != previous else { return false }
        let changed = perform { snapshot in
            snapshot.document.crops[item.id] = next
            snapshot.document.bundle.resize(item.id, width: pixels.width, height: pixels.height)
            for index in snapshot.document.bundle.annotations.indices where snapshot.document.bundle.annotations[index].mediaId == item.id {
                snapshot.document.bundle.annotations[index].shape = Self.reproject(
                    snapshot.document.bundle.annotations[index].shape, from: previous, to: next, original: original
                )
            }
            return true
        }
        guard changed else { return false }
        if let selected = selection, let annotation = annotation(selected), isOutsideEdit(annotation) { selection = nil }
        message = next == nil
            ? "Showing the whole capture."
            : "Cropped to \(pixels.width) × \(pixels.height) px." + outsideNote(item.id, "crop")
        return true
    }

    /// Removes the current media's crop, mapping annotations back onto the original. Undoable.
    @discardableResult
    mutating func resetCrop() -> Bool {
        guard let item = currentMedia, document.crops[item.id] != nil, let original = originalSize(of: item.id) else { return false }
        return perform { snapshot in
            Self.removeCrop(of: item.id, original: original, in: &snapshot)
            return true
        }
    }

    /// Takes `mediaId`'s crop out of `snapshot`, mapping its annotations back onto `original`.
    internal static func removeCrop(of mediaId: String, original: PixelRect, in snapshot: inout Snapshot) {
        guard let crop = snapshot.document.crops[mediaId] else { return }
        snapshot.document.crops[mediaId] = nil
        snapshot.document.bundle.resize(mediaId, width: original.width, height: original.height)
        for index in snapshot.document.bundle.annotations.indices where snapshot.document.bundle.annotations[index].mediaId == mediaId {
            snapshot.document.bundle.annotations[index].shape = reproject(
                snapshot.document.bundle.annotations[index].shape, from: crop, to: nil, original: original
            )
        }
    }

    /// "crop" or "trim": what an annotation lies outside of (hidden, and left out when
    /// submitting), or nil when it shows.
    func outsideReason(_ annotation: Annotation) -> String? {
        guard isOutsideEdit(annotation) else { return nil }
        return document.crops[annotation.mediaId] != nil && EditProjection.isOutside(annotation.shape) ? "crop" : "trim"
    }

    /// `shape`, normalized to crop `from` of `original` (nil: the whole original), normalized to
    /// crop `to` instead. It goes through the original's space, so mapping back to the file stays
    /// exact: the original is never finer than a crop of it.
    internal static func reproject(_ shape: Shape, from previous: PixelRect?, to next: PixelRect?, original: PixelRect) -> Shape {
        let inOriginal = previous.map { EditProjection.shape(shape, outOf: $0, to: original) } ?? shape
        return next.map { EditProjection.shape(inOriginal, into: $0, of: original) } ?? inOriginal
    }
}
