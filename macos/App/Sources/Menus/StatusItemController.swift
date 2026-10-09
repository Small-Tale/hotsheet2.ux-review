import AppKit
import Combine
import UXReviewKit

/// The menu bar icon and its menu, rebuilt from `AppMenus.statusMenu` each time it opens so
/// the capture phase and elapsed recording time are current. Spec: docs/05-start-and-settings.md §5.1.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let item: NSStatusItem
    private let menu = NSMenu()
    private let state: @MainActor () -> MenuState
    private let perform: @MainActor (MenuCommand) -> Void
    private var phaseChanges: AnyCancellable?

    init(
        phase: Published<CapturePhase>.Publisher,
        state: @escaping @MainActor () -> MenuState,
        perform: @escaping @MainActor (MenuCommand) -> Void
    ) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.state = state
        self.perform = perform
        super.init()
        menu.delegate = self
        item.menu = menu
        show(recording: false)
        phaseChanges = phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in MainActor.assumeIsolated { self?.show(recording: phase.isRecording) } }
    }

    /// While recording the icon is a stop button: no menu, and a click stops the recording at
    /// once (`HS2-5GM7Z2`). Otherwise a click opens the menu.
    private func show(recording: Bool) {
        let click = AppMenus.statusItemClick(recording ? .recording(startedAt: Date()) : .idle)
        item.button?.image = StatusBarIcon.image(isRecording: recording)
        item.button?.setAccessibilityLabel(StatusBarIcon.accessibilityLabel(isRecording: recording))
        item.button?.toolTip = recording ? "Stop Recording" : nil
        switch click {
        case .openMenu:
            item.menu = menu
            item.button?.target = nil
            item.button?.action = nil
        case .stopRecording:
            menu.cancelTracking()
            item.menu = nil
            item.button?.target = self
            item.button?.action = #selector(stopRecording(_:))
        }
    }

    @objc private func stopRecording(_: Any?) {
        perform(.stopRecording)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The Capture and Delay pickers keep the menu open; Capture Image and Capture Video read
        // the default request when chosen, so they follow a picker change (docs/05 §5.1).
        MenuRendering.items(AppMenus.statusMenu(state()), perform: perform).forEach(menu.addItem)
    }
}

/// The menu bar icon: UX Review's flame-in-viewfinder template image (Assets.xcassets), or a
/// stop button while recording (a click stops it, `HS2-5GM7Z2`). Spec: docs/05 §5.1.
@MainActor
enum StatusBarIcon {
    static let assetName = "StatusBarIcon"

    static func image(isRecording: Bool) -> NSImage? {
        let image = isRecording
            ? NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: accessibilityLabel(isRecording: true))
            : NSImage(named: assetName)
        image?.isTemplate = true
        return image
    }

    static func accessibilityLabel(isRecording: Bool) -> String {
        isRecording ? "Stop Recording" : "UX Review"
    }
}
