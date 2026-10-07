import AppKit
import UXReviewKit

/// `UXReview --settings [--set-…]`: applies and saves settings changes, registers the global
/// hotkey as the app would, and prints both as JSON. Exit codes: 0 ok, 2 bad arguments.
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
        var defaultCapture: String
    }

    static func run(arguments: [String]) -> Int32 {
        let command: SettingsCommand
        do {
            guard let parsed = try SettingsCommand.parse(arguments) else { return 2 }
            command = parsed
        } catch {
            print(HeadlessCapture.json(["status": "error", "error": "invalidArguments", "message": String(describing: error)]))
            return 2
        }
        let store = AppSettings.defaults
        let settings = command.apply(to: CaptureSettingsStore.load(from: store))
        if command.changesSomething {
            try? CaptureSettingsStore.save(settings, to: store)
        }
        let registration = GlobalHotkeyCenter().register(settings.captureHotkey)
        print(HeadlessCapture.json(Output(
            settings: settings,
            hotkey: .init(status: registration.code, message: registration.message),
            defaultCapture: settings.defaultRequest.summary
        )))
        return 0
    }
}
