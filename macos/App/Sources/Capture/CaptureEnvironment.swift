import AppKit
import CoreGraphics
import UXReviewKit

/// Displays as AppKit sees them, keyed by Core Graphics display id.
@MainActor
enum DisplayDirectory {
    struct Display {
        var id: CGDirectDisplayID
        var screen: NSScreen
        var geometry: ScreenGeometry
    }

    static func displays() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Display(
                id: CGDirectDisplayID(number.uint32Value),
                screen: screen,
                geometry: ScreenGeometry(frame: screen.frame, scale: Double(screen.backingScaleFactor))
            )
        }
    }

    static func screen(for id: CGDirectDisplayID) -> ScreenGeometry? {
        displays().first { $0.id == id }?.geometry
    }

    /// The display under the mouse pointer, falling back to the main display.
    static func displayUnderMouse() -> Display? {
        let all = displays()
        let index = RegionGeometry.screenIndex(containing: NSEvent.mouseLocation, in: all.map(\.geometry))
        return index.map { all[$0] } ?? all.first { $0.id == CGMainDisplayID() } ?? all.first
    }

    /// Height of the primary display (the one with the menu bar), for flipping coordinates.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
    }

    /// Scale of the display holding the center of a window-server (top-left) rect.
    static func scale(containingWindowServerRect rect: CGRect) -> Double {
        let center = WindowSelection.appKitRect(fromWindowServer: rect, primaryHeight: primaryHeight)
        let point = CGPoint(x: center.midX, y: center.midY)
        let all = displays()
        let index = RegionGeometry.screenIndex(containing: point, in: all.map(\.geometry))
        return index.map { all[$0].geometry.scale } ?? Double(NSScreen.main?.backingScaleFactor ?? 2)
    }
}

/// On-screen windows, front to back, from the window server. Titles need Screen Recording
/// permission; without it they are nil.
enum WindowDirectory {
    static func snapshot() -> [WindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap(WindowSnapshot.init(windowInfo:))
    }
}

/// Describes where a capture came from, as of the moment it is taken.
@MainActor
enum CaptureContextProvider {
    static var ownPID: Int32 { ProcessInfo.processInfo.processIdentifier }

    static func context(for source: CaptureSource, displayScale: Double?) -> CaptureContext {
        let windows = WindowDirectory.snapshot()
        let window: WindowSnapshot?
        switch source {
        case let .window(id):
            window = windows.first { $0.windowID == id }
        case let .display(id, region):
            // Name the window under the region's center (or the display's center). That is what
            // the reviewer pointed at, which may not be the frontmost app.
            let bounds = CGDisplayBounds(id)
            let local = region?.sourceRect ?? CGRect(origin: .zero, size: bounds.size)
            let center = CGPoint(x: bounds.minX + local.midX, y: bounds.minY + local.midY)
            let frontmost = frontmostOtherApp()
            if region == nil, let frontmost {
                window = WindowSelection.frontWindow(ofPID: frontmost.processIdentifier, in: windows)
                    ?? WindowSelection.topmostWindow(at: center, in: windows, excludingPID: ownPID)
            } else {
                window = WindowSelection.topmostWindow(at: center, in: windows, excludingPID: ownPID)
            }
        }
        let app = window.flatMap { NSRunningApplication(processIdentifier: $0.ownerPID) } ?? frontmostOtherApp()
        return CaptureContextBuilder.make(
            appName: app?.localizedName ?? window?.ownerName,
            bundleIdentifier: app?.bundleIdentifier,
            windowTitle: window?.title,
            osVersion: ProcessInfo.processInfo.operatingSystemVersion,
            displayScale: displayScale
        )
    }

    /// The frontmost app unless it is UX Review itself.
    static func frontmostOtherApp() -> NSRunningApplication? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.processIdentifier == ownPID ? nil : app
    }
}
