import CoreGraphics

/// The editor's media strip (capture sidebar) width, which the reviewer drags (`HS2-AH6HW4`), and
/// the thumbnail size that follows it. Spec: docs/06-annotation-editor.md §6.1.
public enum MediaStripWidth {
    public static let standard: CGFloat = 112
    public static let minimum: CGFloat = 96
    public static let maximum: CGFloat = 320
    /// Padding around a thumbnail inside the strip (both sides together).
    static let inset: CGFloat = 24
    /// Thumbnails keep the original strip's 88 × 60 proportions.
    static let aspect: CGFloat = 60.0 / 88.0

    /// `width` kept within the allowed range; a saved width that isn't a number becomes standard.
    public static func clamped(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return standard }
        return min(max(width, minimum), maximum)
    }

    /// The strip's width in a window: `width` (clamped), narrowed so the strip fits in the
    /// `available` points the window has left after the canvas's minimum and the inspector
    /// (`HS2-RZVDEQ`); never below `minimum`. The saved width is kept, so the strip widens again
    /// when the window does.
    public static func fitted(_ width: CGFloat, available: CGFloat) -> CGFloat {
        guard available.isFinite else { return clamped(width) }
        return min(clamped(width), max(minimum, available))
    }

    /// Where a divider drag that started at `start` ends up after moving `translation` points.
    public static func dragged(from start: CGFloat, by translation: CGFloat) -> CGFloat {
        clamped(start + translation)
    }

    /// The thumbnail size in a strip of `width`.
    public static func thumbnail(for width: CGFloat) -> CGSize {
        let thumbnailWidth = clamped(width) - inset
        return CGSize(width: thumbnailWidth, height: (thumbnailWidth * aspect).rounded())
    }
}
