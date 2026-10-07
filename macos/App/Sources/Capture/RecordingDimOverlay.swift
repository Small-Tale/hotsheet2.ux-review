import AppKit
import UXReviewKit

/// While a region is being recorded, dims the rest of its display so the reviewer can see what
/// is in the movie (docs/04 §4.9, HS2-122ZFZ). The overlay ignores the mouse, never takes focus,
/// and is kept out of the recording: ScreenCaptureKit's filter excludes all of UX Review's
/// windows, and the window's `sharingType` is `.none` as well. Window and screen recordings get
/// no dim.
@MainActor
final class RecordingDimOverlay {
    private var window: NSWindow?

    var isShowing: Bool { window != nil }

    /// Shows the dim around `region` on `display`, replacing any dim already shown.
    func show(region: DisplayRegion, on display: DisplayDirectory.Display) {
        hide()
        let frame = display.screen.frame
        guard let layout = RecordingDim.layout(region: region, displaySize: frame.size) else { return }
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        // Above app windows, floating panels, and the Dock; below the menu bar, so the Stop
        // control and menus stay undimmed.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = RecordingDimView(frame: CGRect(origin: .zero, size: frame.size), layout: layout)
        window.orderFrontRegardless()
        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

/// Draws a `RecordingDim.Layout`: dim bands and an outline just outside the recorded area.
final class RecordingDimView: NSView {
    let layout: RecordingDim.Layout

    init(frame: CGRect, layout: RecordingDim.Layout) {
        self.layout = layout
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // Click-through even if the window ever stops ignoring mouse events.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        NSColor.black.withAlphaComponent(RecordingDim.dimAlpha).setFill()
        for rect in layout.dimRects {
            rect.fill(using: .sourceOver)
        }
        let outline = NSBezierPath(rect: layout.outline)
        outline.lineWidth = RecordingDim.outlineWidth
        NSColor.systemRed.withAlphaComponent(0.85).setStroke()
        outline.stroke()
    }
}
