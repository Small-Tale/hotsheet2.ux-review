import AppKit
import SwiftUI

/// The one Settings window (menu bar menu or app menu: Settings…, ⌘,). Spec: docs/05 §5.3.
@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show(model: SettingsModel) {
        let controller = shared ?? SettingsWindowController(model: model)
        shared = controller
        guard let window = controller.window else { return }
        if !window.isVisible { window.center() }
        DockPresence.present(window)
    }

    init(model: SettingsModel) {
        let host = NSHostingView(rootView: SettingsView(model: model))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: host.fittingSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "UX Review Settings"
        window.contentView = host
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }
}
