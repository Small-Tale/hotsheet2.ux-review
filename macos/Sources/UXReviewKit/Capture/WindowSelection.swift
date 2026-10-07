import CoreGraphics
import Foundation

/// A window as reported by the window server (`CGWindowListCopyWindowInfo`), front to back.
public struct WindowSnapshot: Equatable, Sendable {
    public var windowID: UInt32
    public var ownerPID: Int32
    public var ownerName: String?
    public var title: String?
    /// Window level; normal app windows are layer 0.
    public var layer: Int
    /// Frame in global coordinates: points, origin at the top-left of the primary display.
    public var frame: CGRect
    public var alpha: Double

    public init(windowID: UInt32, ownerPID: Int32, ownerName: String?, title: String?, layer: Int, frame: CGRect, alpha: Double = 1) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.title = title
        self.layer = layer
        self.frame = frame
        self.alpha = alpha
    }

    /// Reads one entry of `CGWindowListCopyWindowInfo`. Returns nil for malformed entries.
    public init?(windowInfo info: [String: Any]) {
        guard let number = info[kCGWindowNumber as String] as? NSNumber,
              let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        self.init(
            windowID: number.uint32Value,
            ownerPID: pid.int32Value,
            ownerName: info[kCGWindowOwnerName as String] as? String,
            title: info[kCGWindowName as String] as? String,
            layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            frame: frame,
            alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        )
    }
}

/// Picks windows for window capture and for capture context.
public enum WindowSelection {
    /// Windows narrower or shorter than this (points) are decorations, not pickable windows.
    public static let minimumSide: CGFloat = 40

    /// Whether a window is an ordinary, visible app window that can be picked.
    public static func isPickable(_ window: WindowSnapshot, excludingPID: Int32?) -> Bool {
        window.layer == 0 && window.alpha > 0 && window.ownerPID != excludingPID
            && window.frame.width >= minimumSide && window.frame.height >= minimumSide
    }

    /// The frontmost pickable window under `point` (global, top-left coordinates). `windows` must
    /// be in front-to-back order, as the window server lists them.
    public static func topmostWindow(at point: CGPoint, in windows: [WindowSnapshot], excludingPID: Int32?) -> WindowSnapshot? {
        windows.first { isPickable($0, excludingPID: excludingPID) && $0.frame.contains(point) }
    }

    /// The frontmost pickable window owned by `pid`, used to name the window being reviewed.
    public static func frontWindow(ofPID pid: Int32, in windows: [WindowSnapshot]) -> WindowSnapshot? {
        windows.first { $0.ownerPID == pid && isPickable($0, excludingPID: nil) }
    }

    /// Converts a point from AppKit global coordinates (bottom-left origin) to window-server
    /// coordinates (top-left origin of the primary display, whose height is `primaryHeight`).
    public static func windowServerPoint(fromAppKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Converts a window-server rect (top-left origin) to AppKit global coordinates.
    public static func appKitRect(fromWindowServer rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
