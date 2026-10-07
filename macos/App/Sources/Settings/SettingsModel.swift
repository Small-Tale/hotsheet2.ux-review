import AppKit
import UXReviewKit

/// Live capture settings: persisted in the app's defaults, with the global hotkey kept
/// registered to match. Spec: docs/05-start-and-settings.md §5.3.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings: CaptureSettings
    @Published private(set) var registration: GlobalHotkeyCenter.Registration = .disabled

    let hotkeys = GlobalHotkeyCenter()
    private let store: KeyValueStoring

    init(store: KeyValueStoring = AppSettings.defaults) {
        self.store = store
        settings = CaptureSettingsStore.load(from: store)
        registration = hotkeys.register(settings.captureHotkey)
    }

    func update(_ change: (inout CaptureSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let hotkeyChanged = next.captureHotkey != settings.captureHotkey
        settings = next
        try? CaptureSettingsStore.save(next, to: store)
        if hotkeyChanged { registration = hotkeys.register(next.captureHotkey) }
    }

    /// While the shortcut recorder listens, the current hotkey must not fire.
    func suspendHotkey() {
        hotkeys.unregister()
    }

    func resumeHotkey() {
        registration = hotkeys.register(settings.captureHotkey)
    }
}

extension AppSettings {
    /// The app's defaults; `UXREVIEW_DEFAULTS_SUITE` selects a separate suite (tests).
    static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["UXREVIEW_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
