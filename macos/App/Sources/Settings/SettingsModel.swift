import AppKit
import UXReviewKit

/// Live capture settings: persisted in the app's defaults, with the global hotkeys kept
/// registered to match. Spec: docs/05-start-and-settings.md §5.3.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings: CaptureSettings
    @Published private(set) var registrations: [HotkeySlot: GlobalHotkeyCenter.Registration] = [:]

    let hotkeys = GlobalHotkeyCenter()
    private let store: KeyValueStoring

    init(store: KeyValueStoring = AppSettings.defaults) {
        self.store = store
        settings = CaptureSettingsStore.load(from: store)
        registrations = hotkeys.register(settings)
    }

    func registration(_ slot: HotkeySlot) -> GlobalHotkeyCenter.Registration {
        registrations[slot] ?? .disabled
    }

    /// The slot's hotkey when it is actually registered (so it is worth showing in menus/hints).
    func activeHotkey(_ slot: HotkeySlot) -> Hotkey? {
        if case let .registered(hotkey) = registration(slot) { hotkey } else { nil }
    }

    func update(_ change: (inout CaptureSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let hotkeysChanged = HotkeySlot.allCases.contains { next[$0] != settings[$0] }
        settings = next
        try? CaptureSettingsStore.save(next, to: store)
        if hotkeysChanged { registrations = hotkeys.register(next) }
        NotificationCenter.default.post(name: .captureSettingsChanged, object: nil)
    }

    /// While a shortcut recorder listens, no hotkey may fire, so pressing one records it.
    func suspendHotkeys() {
        hotkeys.unregister()
    }

    func resumeHotkeys() {
        registrations = hotkeys.register(settings)
    }
}

extension AppSettings {
    /// The app's defaults; `UXREVIEW_DEFAULTS_SUITE` selects a separate suite (tests).
    static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["UXREVIEW_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
