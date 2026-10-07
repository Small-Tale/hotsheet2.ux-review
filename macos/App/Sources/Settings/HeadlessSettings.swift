import AppKit
import UXReviewKit

/// `UXReview --settings [--set-…]`: applies and saves settings changes, registers the global
/// hotkeys as the app would, and prints the settings and registrations as JSON. Exit codes: 0 ok, 2 bad arguments.
/// Spec: docs/05-start-and-settings.md §5.5.
@MainActor
enum HeadlessSettings {
    struct Output: Encodable {
        struct HotkeyStatus: Encodable {
            var status: String
            var message: String
        }

        var settings: CaptureSettings
        var hotkey: HotkeyStatus
        var recordHotkey: HotkeyStatus
        var defaultCapture: String
    }

    static func run(arguments: [String]) -> Int32 {
        let store = AppSettings.defaults
        let command: SettingsCommand
        let settings: CaptureSettings
        do {
            guard let parsed = try SettingsCommand.parse(arguments) else { return 2 }
            command = parsed
            settings = try command.apply(to: CaptureSettingsStore.load(from: store))
        } catch {
            print(HeadlessCapture.json(["status": "error", "error": "invalidArguments", "message": String(describing: error)]))
            return 2
        }
        if command.changesSomething {
            try? CaptureSettingsStore.save(settings, to: store)
        }
        let registrations = GlobalHotkeyCenter().register(settings)
        func status(_ slot: HotkeySlot) -> Output.HotkeyStatus {
            let registration = registrations[slot] ?? .disabled
            return .init(status: registration.code, message: registration.message(for: slot))
        }
        print(HeadlessCapture.json(Output(
            settings: settings,
            hotkey: status(.capture),
            recordHotkey: status(.record),
            defaultCapture: settings.defaultRequest.summary
        )))
        return 0
    }
}
