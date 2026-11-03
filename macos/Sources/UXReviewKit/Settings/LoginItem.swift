import Foundation

/// Whether UX Review opens when the reviewer logs in (Settings › General, `HS2-QNXVDA`).
/// The system's login-item registration is the source of truth, not a saved preference: the
/// reviewer can also turn it off in System Settings › General › Login Items, and Settings
/// must show that. Spec: docs/05-start-and-settings.md §5.3.
public enum LoginItemStatus: String, Codable, Sendable, CaseIterable {
    /// Registered and allowed: UX Review opens at login.
    case enabled
    /// Registered, but the reviewer must allow it in System Settings › Login Items.
    case requiresApproval
    /// Not registered.
    case notRegistered
    /// `SMAppService` has no record of the app. macOS reports this for an app that was never
    /// registered (verified on macOS 27), so it reads as off; a real registration failure
    /// is thrown by `setEnabled` instead.
    case notFound

    /// What the Open at login switch shows: on when UX Review is registered, even while the
    /// system still waits for approval, so turning it off unregisters it.
    public var isOn: Bool {
        switch self {
        case .enabled, .requiresApproval: true
        case .notRegistered, .notFound: false
        }
    }

    /// The caption under the switch.
    public var message: String {
        switch self {
        case .enabled: "UX Review opens in the menu bar when you log in."
        case .requiresApproval: "Allow UX Review in System Settings › General › Login Items to finish turning this on."
        case .notRegistered, .notFound: "UX Review opens only when you start it."
        }
    }
}

/// Registers UX Review to open at login. The app uses `SMAppService.mainApp`; tests use
/// `PreferencesLoginItem`, so they never add a login item to the machine running them.
@MainActor
public protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    /// Registers (`true`) or unregisters (`false`). Throws when the system refuses.
    func setEnabled(_ enabled: Bool) throws
    /// Opens System Settings › General › Login Items.
    func openSystemSettings()
}

/// A stand-in login item kept in the (test) preferences, used whenever
/// `UXREVIEW_DEFAULTS_SUITE` isolates the app. `UXREVIEW_TEST_LOGIN_ITEM_APPROVAL=1` makes
/// registration wait for approval, like a first registration on a real Mac.
@MainActor
public final class PreferencesLoginItem: LoginItemControlling {
    public static let key = "testLoginItem"
    public static let openedSettingsKey = "testLoginItemOpenedSettings"
    private let store: KeyValueStoring
    private let requiresApproval: Bool

    public init(store: KeyValueStoring, requiresApproval: Bool = false) {
        self.store = store
        self.requiresApproval = requiresApproval
    }

    public var status: LoginItemStatus {
        store.data(forKey: Self.key)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(LoginItemStatus.init(rawValue:)) ?? .notRegistered
    }

    public func setEnabled(_ enabled: Bool) throws {
        let next: LoginItemStatus = enabled ? (requiresApproval ? .requiresApproval : .enabled) : .notRegistered
        store.set(Data(next.rawValue.utf8), forKey: Self.key)
    }

    public func openSystemSettings() {
        store.set(Data("1".utf8), forKey: Self.openedSettingsKey)
    }
}
