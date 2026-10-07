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
