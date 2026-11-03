import Foundation
import ServiceManagement
import UXReviewKit

/// Open at login through `SMAppService.mainApp` (`HS2-QNXVDA`, docs/05 §5.3).
@MainActor
final class SystemLoginItem: LoginItemControlling {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

extension AppSettings {
    /// The login item the app controls. Under `UXREVIEW_DEFAULTS_SUITE` (tests) it is a stand-in
    /// kept in the test preferences, so a test run never registers a login item on its machine.
    @MainActor
    static func makeLoginItem() -> any LoginItemControlling {
        let environment = ProcessInfo.processInfo.environment
        guard environment["UXREVIEW_DEFAULTS_SUITE"] != nil else { return SystemLoginItem() }
        return PreferencesLoginItem(store: defaults, requiresApproval: environment["UXREVIEW_TEST_LOGIN_ITEM_APPROVAL"] == "1")
    }
}
