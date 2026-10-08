import CoreGraphics

/// Keeps a restored window frame on its screen (`HS2-VX8T5A`). A saved frame can be taller than
/// the screen (SwiftUI used to force some windows that tall, and the frame was then saved) or lie
/// off screen after a display goes away. Spec: docs/05-start-and-settings.md §5.1.1.
public enum WindowFrameFit {
    /// `frame` shrunk to fit `visible` (never below `minSize`) and moved inside it. The top edge
    /// stays where it was when the frame already fits there. A frame that fits is returned as is.
    /// A side longer than the screen can't have been chosen by the reviewer, so it goes back to
    /// `defaultSize` (the window's opening size) when one is given, else to the screen's length.
    public static func fit(_ frame: CGRect, in visible: CGRect, minSize: CGSize = .zero, defaultSize: CGSize? = nil) -> CGRect {
        guard !visible.isEmpty, !frame.isNull else { return frame }
        func side(_ length: CGFloat, screen: CGFloat, minimum: CGFloat, standard: CGFloat?) -> CGFloat {
            guard length > screen else { return length }
            return max(min(standard ?? screen, screen), minimum)
        }
        let size = CGSize(
            width: side(frame.width, screen: visible.width, minimum: minSize.width, standard: defaultSize?.width),
            height: side(frame.height, screen: visible.height, minimum: minSize.height, standard: defaultSize?.height)
        )
        // Wider than the screen even at its minimum: the left edge goes to the screen's left.
        let x = size.width > visible.width
            ? visible.minX
            : min(max(frame.minX, visible.minX), visible.maxX - size.width)
        // Keep the top edge, pulled inside the screen. Taller than the screen even at its
        // minimum: the top goes to the screen's top, so the title bar stays reachable.
        let y = size.height > visible.height
            ? visible.maxY - size.height
            : min(max(frame.maxY - size.height, visible.minY), visible.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
