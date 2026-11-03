import AppKit
import UXReviewKit

/// Live capture settings: persisted in the app's defaults, with the global hotkeys kept
/// registered to match. Spec: docs/05-start-and-settings.md §5.3.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings: CaptureSettings
    @Published private(set) var registrations: [HotkeySlot: GlobalHotkeyCenter.Registration] = [:]

    /// Open at login, read back from the system each time (`HS2-QNXVDA`).
    @Published private(set) var loginItemStatus: LoginItemStatus = .notRegistered
    /// Why the last Open at login change failed, until the next change or refresh.
    @Published private(set) var loginItemError: String?

    let hotkeys = GlobalHotkeyCenter()
    private let store: KeyValueStoring
    private let loginItem: any LoginItemControlling

    init(store: KeyValueStoring = AppSettings.defaults, loginItem: (any LoginItemControlling)? = nil) {
        self.store = store
        self.loginItem = loginItem ?? AppSettings.makeLoginItem()
        settings = CaptureSettingsStore.load(from: store)
        registrations = hotkeys.register(settings)
        loginItemStatus = self.loginItem.status
    }

    /// Re-reads Open at login; the reviewer may have changed it in System Settings.
    func refreshLoginItem() {
        loginItemStatus = loginItem.status
    }

    /// Registers or unregisters the login item, then shows what the system reports.
    func setOpenAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change Open at login: \(error.localizedDescription)"
        }
        loginItemStatus = loginItem.status
    }

    func openLoginItemsSettings() {
        loginItem.openSystemSettings()
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
    static var defaults: any PreferencesStoring {
        if let isolatedDefaults { return isolatedDefaults }
        return nativeDefaults
    }

    static var isolatedDefaults: FilePreferences? {
        guard let path = ProcessInfo.processInfo.environment["UXREVIEW_DEFAULTS_SUITE"], path.hasPrefix("/") else { return nil }
        return FilePreferences(url: URL(fileURLWithPath: path).appendingPathExtension("plist"))
    }

    /// File overrides use their own observable bridge; ordinary suites retain native AppStorage.
    static var nativeDefaults: UserDefaults {
        guard isolatedDefaults == nil else { return .standard }
        return ProcessInfo.processInfo.environment["UXREVIEW_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
