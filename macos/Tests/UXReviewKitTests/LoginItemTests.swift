import Foundation
import Testing
@testable import UXReviewKit

/// HS2-QNXVDA: Open at login (Settings › General, `--settings --set-open-at-login`).
@MainActor
struct LoginItemTests {
    @Test func switchShowsOnWhileRegisteredOrAwaitingApproval() {
        #expect(LoginItemStatus.enabled.isOn)
        #expect(LoginItemStatus.requiresApproval.isOn)
        #expect(!LoginItemStatus.notRegistered.isOn)
        #expect(!LoginItemStatus.notFound.isOn)
        for status in LoginItemStatus.allCases {
            #expect(!status.message.isEmpty)
        }
        #expect(LoginItemStatus.requiresApproval.message.contains("Login Items"))
        // macOS reports notFound for a never-registered app: it reads exactly like off.
        #expect(LoginItemStatus.notFound.message == LoginItemStatus.notRegistered.message)
    }

    @Test func parsesTheOpenAtLoginSwitchWithoutTouchingCaptureSettings() throws {
        let turnOn = try #require(try SettingsCommand.parse(["--settings", "--set-open-at-login", "ON"]))
        #expect(turnOn.openAtLogin == true && turnOn.changesSomething)
        #expect(try turnOn.apply(to: CaptureSettings()) == CaptureSettings())
        #expect(try SettingsCommand.parse(["--settings", "--set-open-at-login", "off"])?.openAtLogin == false)
        #expect(try SettingsCommand.parse(["--settings"])?.openAtLogin == nil)
        #expect(throws: CommandLineError.invalidValue("--set-open-at-login", "yes")) {
            try SettingsCommand.parse(["--settings", "--set-open-at-login", "yes"])
        }
    }

    /// The test stand-in walks every transition: off → on → on again → off → off again → on.
    @Test func preferencesStandInRegistersAndUnregisters() throws {
        let store = MemoryStore()
        let item = PreferencesLoginItem(store: store)
        #expect(item.status == .notRegistered)
        for (enabled, expected) in [
            (true, LoginItemStatus.enabled),
            (true, .enabled),
            (false, .notRegistered),
            (false, .notRegistered),
            (true, .enabled),
        ] {
            try item.setEnabled(enabled)
            #expect(item.status == expected)
            // A second instance over the same store (another process) sees the same state.
            #expect(PreferencesLoginItem(store: store).status == expected)
        }
    }

    @Test func preferencesStandInCanWaitForApproval() throws {
        let store = MemoryStore()
        let item = PreferencesLoginItem(store: store, requiresApproval: true)
        try item.setEnabled(true)
        #expect(item.status == .requiresApproval && item.status.isOn)
        #expect(store.data(forKey: PreferencesLoginItem.openedSettingsKey) == nil)
        item.openSystemSettings()
        #expect(store.data(forKey: PreferencesLoginItem.openedSettingsKey) != nil)
        try item.setEnabled(false)
        #expect(item.status == .notRegistered)
    }

    @Test func unreadableStandInStateReadsAsNotRegistered() {
        let store = MemoryStore()
        store.set(Data("garbage".utf8), forKey: PreferencesLoginItem.key)
        #expect(PreferencesLoginItem(store: store).status == .notRegistered)
    }
}
