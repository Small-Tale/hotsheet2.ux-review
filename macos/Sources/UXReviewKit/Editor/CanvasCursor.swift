import CoreGraphics
import Foundation

/// The pointer the canvas shows (`HS2-9RRP8G`). The app maps it to an `NSCursor`; the rules live
/// here so they are unit-tested. Spec: docs/06-annotation-editor.md §6.3, §6.6.
public enum CanvasCursor: Equatable, Sendable {
    /// The Select tool.
    case arrow
    /// A drawing tool, or the Crop tool away from the crop rectangle (a new crop).
    case crosshair
    /// The Crop tool inside a crop: dragging moves it.
    case openHand
    /// The crop being moved.
    case closedHand
    /// The Crop tool on an edge or corner of the crop rectangle, or resizing from it: left-right
    /// on the left and right edges, up-down on the top and bottom, diagonal on the corners.
    case resize(BoxHandle)

    /// The cursor over a crop handle.
    public init(_ handle: CropHandle) {
        switch handle {
        case .move: self = .openHand
        case let .edge(box): self = .resize(box)
        }
    }
}

public extension AnnotationEditor {
    /// The cursor with the pointer at `point` (pixels of `canvasFrame`; nil when unknown or off
    /// the media), hit-testing crop edges within `tolerance` pixels (the canvas passes its screen
    /// tolerance divided by the zoom, as it does for presses):
    /// - Select: arrow; drawing tools: crosshair;
    /// - Crop tool: during a move, a closed hand; during a resize, that edge's or corner's resize
    ///   cursor; while drawing a new crop, a crosshair; otherwise what a press at `point` would
    ///   grab (`cropHandle`): an edge or corner's resize cursor, an open hand inside a crop, else
    ///   a crosshair.
    func canvasCursor(at point: CGPoint?, tolerance: Double) -> CanvasCursor {
        guard showsOriginal else { return tool == .select ? .arrow : .crosshair }
        switch gesture {
        case let .adjustingCrop(handle, _, _, _): return handle == .move ? .closedHand : CanvasCursor(handle)
        case .cropping: return .crosshair
        default: break
        }
        guard let point, let handle = cropHandle(at: point, tolerance: tolerance) else { return .crosshair }
        return CanvasCursor(handle)
    }
}
