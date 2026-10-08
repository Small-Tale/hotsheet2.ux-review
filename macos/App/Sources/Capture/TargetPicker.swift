import AppKit
import UXReviewKit

/// Lets the reviewer choose what to capture. Display needs no UI (the display under the
/// pointer); region shows a crosshair overlay to drag a rectangle; window highlights the window
/// under the pointer and takes it on click. Esc cancels. Spec: docs/04-capture.md §4.2.
@MainActor
enum TargetPicker {
    static func pick(_ target: CaptureTarget) async throws -> CaptureSource {
        switch target {
        case .display:
            guard let display = DisplayDirectory.displayUnderMouse() else { throw CaptureFailure.targetUnavailable("The display") }
            return .display(id: display.id, region: nil)
        case .region, .window:
            let session = PickerSession(mode: target)
            return try await session.run()
        }
    }
}

/// What an overlay draws. `PickerSession` is the live implementation; UI previews use fixed state.
@MainActor
protocol OverlayState: AnyObject {
    var mode: CaptureTarget { get }
    /// Region mode: the dragged rectangle in global AppKit coordinates.
    var selection: CGRect? { get }
    /// Window mode: the hovered window and its frame in global AppKit coordinates.
    var hovered: WindowSnapshot? { get }
    var hoveredFrame: CGRect? { get }
}

/// One overlay window per display, all sharing a session's state. The overlays are
/// non-activating panels: picking never activates UX Review, so its own windows (the editor,
/// Submit Review, Settings) are not raised over the app being reviewed, and the window order the
/// picker snapshotted stays the order on screen (HS2-AR8Q2G).
@MainActor
final class PickerSession: OverlayState {
    let mode: CaptureTarget
    private var overlays: [OverlayWindow] = []
    private var continuation: CheckedContinuation<CaptureSource, Error>?
    private let windows: [WindowSnapshot]
    private let primaryHeight = DisplayDirectory.primaryHeight
    private var previousApp: NSRunningApplication?
    private weak var previousKeyWindow: NSWindow?

    private(set) var dragStart: CGPoint?
    private(set) var dragCurrent: CGPoint?
    private(set) var hovered: WindowSnapshot?

    init(mode: CaptureTarget) {
        self.mode = mode
        windows = mode == .window ? WindowDirectory.snapshot() : []
    }

    func run() async throws -> CaptureSource {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            previousApp = CaptureContextProvider.frontmostOtherApp()
            previousKeyWindow = NSApp.keyWindow
            overlays = DisplayDirectory.displays().map { OverlayWindow(display: $0, session: self) }
            // No `NSApp.activate`: the overlay panel takes key (for Esc) without activating.
            for overlay in overlays {
                overlay.orderFrontRegardless()
            }
            let mouse = NSEvent.mouseLocation
            (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
            if mode == .window { updateHover(at: mouse) }
        }
    }

    /// Global AppKit coordinates of the current drag, if any.
    var selection: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return RegionGeometry.dragRect(from: dragStart, to: dragCurrent)
    }

    /// The hovered window's frame in global AppKit coordinates.
    var hoveredFrame: CGRect? {
        hovered.map { WindowSelection.appKitRect(fromWindowServer: $0.frame, primaryHeight: primaryHeight) }
    }

    func mouseDown(at point: CGPoint, on display: DisplayDirectory.Display) {
        switch mode {
        case .region:
            dragStart = point
            dragCurrent = point
            redraw()
        case .window:
            updateHover(at: point)
            guard let hovered else { return }
            finish(.success(.window(id: hovered.windowID)))
        case .display:
            finish(.success(.display(id: display.id, region: nil)))
        }
    }

    func mouseDragged(to point: CGPoint, on display: DisplayDirectory.Display) {
        guard mode == .region, dragStart != nil else { return }
        // Keep the drag on the display where it started.
        let frame = display.geometry.frame
        dragCurrent = CGPoint(x: min(max(point.x, frame.minX), frame.maxX), y: min(max(point.y, frame.minY), frame.maxY))
        redraw()
    }

    func mouseUp(on display: DisplayDirectory.Display) {
        guard mode == .region, let selection else { return }
        if let region = RegionGeometry.displayRegion(forGlobal: selection, on: display.geometry) {
            finish(.success(.display(id: display.id, region: region)))
        } else {
            // A click without a real drag: start over rather than capturing a sliver.
            dragStart = nil
            dragCurrent = nil
            redraw()
        }
    }

    func updateHover(at point: CGPoint) {
        guard mode == .window else { return }
        let serverPoint = WindowSelection.windowServerPoint(fromAppKit: point, primaryHeight: primaryHeight)
        let next = WindowSelection.pickTarget(at: serverPoint, in: windows, ownPID: CaptureContextProvider.ownPID)
        if next != hovered {
            hovered = next
            redraw()
        }
    }

    func cancel() {
        finish(.failure(CaptureFailure.cancelled))
    }

    private func redraw() {
        for overlay in overlays {
            overlay.contentView?.needsDisplay = true
        }
    }

    private func finish(_ result: Result<CaptureSource, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        for overlay in overlays {
            overlay.orderOut(nil)
        }
        overlays.removeAll()
        restoreFocus()
        continuation.resume(with: result)
    }

    /// The overlays never activate UX Review, so focus normally never moved. If UX Review did
    /// become active meanwhile, hand focus back to the reviewed app so its hover states and menus
    /// behave normally; if UX Review was frontmost to begin with, give its key window back.
    private func restoreFocus() {
        let ownPID = CaptureContextProvider.ownPID
        if let pid = PickerFocus.appToReactivate(
            previousPID: previousApp?.processIdentifier,
            frontmostPIDNow: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownPID: ownPID
        ) {
            NSRunningApplication(processIdentifier: pid)?.activate()
        } else if NSApp.isActive, let previousKeyWindow, previousKeyWindow.isVisible {
            previousKeyWindow.makeKey()
        }
    }
}

/// Borderless, transparent, above everything, on every Space. A non-activating panel: it becomes
/// key so Esc reaches it, but showing or clicking it never activates UX Review.
final class OverlayWindow: NSPanel {
    init(display: DisplayDirectory.Display, session: PickerSession) {
        // `.nonactivatingPanel` must be set at creation to take effect in the window server.
        super.init(
            contentRect: display.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        setFrame(display.screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = OverlayView(display: display, session: session)
    }

    override var canBecomeKey: Bool { true }
}

final class OverlayView: NSView {
    private let display: DisplayDirectory.Display
    private weak var session: PickerSession?
    private weak var state: OverlayState?

    init(display: DisplayDirectory.Display, session: PickerSession?, state: OverlayState? = nil) {
        self.display = display
        self.session = session
        self.state = state ?? session
        super.init(frame: CGRect(origin: .zero, size: display.screen.frame.size))
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func cursorUpdate(with _: NSEvent) {
        NSCursor.crosshair.set()
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func mouseDown(with event: NSEvent) {
        session?.mouseDown(at: globalPoint(event), on: display)
    }

    override func mouseDragged(with event: NSEvent) {
        session?.mouseDragged(to: globalPoint(event), on: display)
    }

    override func mouseUp(with _: NSEvent) {
        session?.mouseUp(on: display)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        session?.updateHover(at: globalPoint(event))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { session?.cancel() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_: Any?) {
        session?.cancel()
    }

    override func draw(_: NSRect) {
        guard let session = state else { return }
        let origin = display.geometry.frame.origin
        let highlight = (session.mode == .region ? session.selection : session.hoveredFrame)
            .map { $0.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds) }
            .flatMap { $0.isNull || $0.isEmpty ? nil : $0 }

        let dim = NSBezierPath(rect: bounds)
        if let highlight {
            dim.append(NSBezierPath(rect: highlight))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.3).setFill()
        dim.fill()

        guard let highlight else {
            drawHint(session.mode == .region ? "Drag to select a region · Esc to cancel" : "Click a window to capture it · Esc to cancel")
            return
        }
        NSColor.controlAccentColor.withAlphaComponent(session.mode == .window ? 0.18 : 0).setFill()
        highlight.fill()
        let border = NSBezierPath(rect: highlight.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        border.stroke()

        if session.mode == .region {
            let scale = display.geometry.scale
            drawLabel("\(Int((highlight.width * scale).rounded())) × \(Int((highlight.height * scale).rounded()))", near: highlight)
        } else if let window = session.hovered {
            drawLabel(
                [window.ownerName, window.title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "),
                near: highlight
            )
        }
    }

    private func drawHint(_ text: String) {
        let label = Self.attributed(text, size: 15)
        let size = label.size()
        let box = CGRect(
            x: bounds.midX - size.width / 2 - 14,
            y: bounds.midY - size.height / 2 - 8,
            width: size.width + 28,
            height: size.height + 16
        )
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        label.draw(at: CGPoint(x: box.minX + 14, y: box.minY + 8))
    }

    private func drawLabel(_ text: String, near rect: CGRect) {
        guard !text.isEmpty else { return }
        let label = Self.attributed(text, size: 12)
        let size = label.size()
        var box = CGRect(x: rect.minX, y: rect.minY - size.height - 10, width: size.width + 12, height: size.height + 6)
        // Prefer below the rectangle, then above it, and only then inside, so the label never
        // hides what is being selected unless the selection fills the screen.
        if box.minY < bounds.minY + 4 {
            box.origin.y = rect.maxY + 6
            if box.maxY > bounds.maxY - 4 { box.origin.y = rect.maxY - box.height - 6 }
        }
        box.origin.x = min(max(box.minX, bounds.minX + 4), bounds.maxX - box.width - 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }

    private static func attributed(_ text: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
    }
}
