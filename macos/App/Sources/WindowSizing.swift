import AppKit
import SwiftUI
import UXReviewKit

/// Saved frames for UX Review's resizable SwiftUI windows: Draft Reviews, Submit Review, and the
/// editor (`HS2-VX8T5A`). Spec: docs/05-start-and-settings.md §5.1.1.
///
/// Their minimum size comes from SwiftUI: an `NSHostingView` sets the window's minimum to its
/// root view's, and SwiftUI measures the minimum height at the minimum width. Each root view
/// therefore states a minimum width (and height) with `.frame(minWidth:minHeight:)`. Without one,
/// wrapping text stacks one word per line at a 99 pt width, which forced the empty Draft Reviews
/// window to 1766 pt and a filed review's Submit Review window past 2000 pt.
@MainActor
enum WindowSizing {
    /// Off for `--render-ui-previews`, so its windows never read or write the user's saved frames.
    static var restoresFrames = true

    /// Restores the window's frame saved under `name` (and saves it from now on), kept on screen.
    /// Call it on the new window at its opening size, after setting `contentMinSize`.
    static func restoreFrame(_ window: NSWindow, name: String) {
        guard restoresFrames else { return }
        let opening = window.frame.size
        window.setFrameAutosaveName(name)
        keepOnScreen(window, defaultSize: opening)
    }

    /// Shrinks and moves the window into its screen's visible area (`WindowFrameFit`); a side
    /// longer than the screen goes back to `defaultSize`.
    static func keepOnScreen(_ window: NSWindow, defaultSize: CGSize? = nil) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let minimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
        let fitted = WindowFrameFit.fit(window.frame, in: visible, minSize: minimum, defaultSize: defaultSize)
        if fitted != window.frame { window.setFrame(fitted, display: false) }
    }
}
