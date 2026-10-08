import AppKit
import UXReviewKit

/// Shows the Dock icon and app menu bar while a UX Review window (editor, Submit Review, Draft
/// Reviews, Settings) is open, so the reviewer can ⌘-Tab to it, drop files on its Dock icon,
/// and use its menus; back to a menu-bar-only app when the last one closes. The rule is
/// `WindowPresence`. Spec: docs/05-start-and-settings.md §5.1.1.
@MainActor
enum DockPresence {
    private static var presence = WindowPresence()
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Counts `window` as open until it closes. Call before activating the app to show it.
    static func track(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard observers[id] == nil else { return }
        observers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { untrack(id) }
        }
        if presence.opened(key(id)) { apply() }
    }

    static var policy: WindowPresence.Policy { presence.policy }

    /// Tracks `window`, activates UX Review, and puts the window in front of every other app's
    /// windows (`HS2-SZ6T9T`). Since macOS 14 activation is cooperative: a request can be refused
    /// or land late, notably from the menu bar menu (the previous app takes focus back as the menu
    /// closes) or right after the activation policy turns `.regular`. `makeKeyAndOrderFront`
    /// alone then leaves the window behind the active app's windows, so it is also ordered front
    /// regardless, and activation is asked again once the run loop turns.
    static func present(_ window: NSWindow) {
        track(window)
        NSApp.unhide(nil)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard window.isVisible else { return }
                if !NSApp.isActive { NSApp.activate() }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private static func untrack(_ id: ObjectIdentifier) {
        if let observer = observers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        if presence.closed(key(id)) { apply() }
    }

    private static func key(_ id: ObjectIdentifier) -> String {
        String(UInt(bitPattern: id.hashValue))
    }

    private static func apply() {
        switch presence.policy {
        case .regular: NSApp.setActivationPolicy(.regular)
        case .accessory: NSApp.setActivationPolicy(.accessory)
        }
    }
}
