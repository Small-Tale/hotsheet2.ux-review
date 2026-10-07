import Foundation

/// Headless settings invocation of the app, used by scripts and end-to-end tests:
///
///     UXReview --settings [--set-hotkey ⌥⇧⌘U|none] [--set-target display|window|region] [--set-delay N]
///
/// Applies the changes (if any), saves them, registers the hotkey, and prints the result.
/// Spec: docs/05-start-and-settings.md §5.5.
public struct SettingsCommand: Equatable, Sendable {
    /// `.some(nil)` disables the hotkey.
    public var hotkey: Hotkey??
    public var target: CaptureTarget?
    public var delaySeconds: Int?

    public init(hotkey: Hotkey?? = nil, target: CaptureTarget? = nil, delaySeconds: Int? = nil) {
        self.hotkey = hotkey
        self.target = target
        self.delaySeconds = delaySeconds
    }

    public var changesSomething: Bool { hotkey != nil || target != nil || delaySeconds != nil }

    /// Returns nil when `--settings` is absent.
    public static func parse(_ arguments: [String]) throws -> SettingsCommand? {
        guard arguments.contains("--settings") else { return nil }
        let values = ArgumentValues(arguments)
        var command = SettingsCommand()
        if let text = try values.optional("--set-hotkey") {
            if text.lowercased() == "none" {
                command.hotkey = .some(nil)
            } else {
                guard let hotkey = Hotkey(text) else { throw CommandLineError.invalidValue("--set-hotkey", text) }
                if let problem = hotkey.problem { throw CommandLineError.invalidValue("--set-hotkey", "\(text): \(problem)") }
                command.hotkey = .some(hotkey)
            }
        }
        command.target = try values.optional("--set-target").map { text in
            guard let target = CaptureTarget(rawValue: text) else { throw CommandLineError.invalidValue("--set-target", text) }
            return target
        }
        command.delaySeconds = try values.optional("--set-delay").map { text in
            guard let seconds = Int(text), (0 ... CaptureRequest.maxDelaySeconds).contains(seconds) else {
                throw CommandLineError.invalidValue("--set-delay", text)
            }
            return seconds
        }
        return command
    }

    public func apply(to settings: CaptureSettings) -> CaptureSettings {
        var settings = settings
        if let hotkey { settings.captureHotkey = hotkey }
        if let target { settings.defaultRequest.target = target }
        if let delaySeconds { settings.defaultRequest.delaySeconds = delaySeconds }
        return settings
    }
}
