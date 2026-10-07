import Foundation

/// Headless settings invocation of the app, used by scripts and end-to-end tests:
///
///     UXReview --settings [--set-hotkey ⌥⇧⌘U|none] [--set-record-hotkey ⌥⇧⌘V|none]
///                         [--set-target display|window|region] [--set-delay N]
///
/// Applies the changes (if any), saves them, registers the hotkeys, and prints the result.
/// Spec: docs/05-start-and-settings.md §5.5.
public struct SettingsCommand: Equatable, Sendable {
    /// `.some(nil)` disables the hotkey.
    public var hotkey: Hotkey??
    /// `.some(nil)` disables the record-video hotkey.
    public var recordHotkey: Hotkey??
    public var target: CaptureTarget?
    public var delaySeconds: Int?

    public init(hotkey: Hotkey?? = nil, recordHotkey: Hotkey?? = nil, target: CaptureTarget? = nil, delaySeconds: Int? = nil) {
        self.hotkey = hotkey
        self.recordHotkey = recordHotkey
        self.target = target
        self.delaySeconds = delaySeconds
    }

    public var changesSomething: Bool { hotkey != nil || recordHotkey != nil || target != nil || delaySeconds != nil }

    static let hotkeyFlags: [(HotkeySlot, String)] = [(.capture, "--set-hotkey"), (.record, "--set-record-hotkey")]

    /// Returns nil when `--settings` is absent.
    public static func parse(_ arguments: [String]) throws -> SettingsCommand? {
        guard arguments.contains("--settings") else { return nil }
        let values = ArgumentValues(arguments)
        var command = SettingsCommand()
        command.hotkey = try parseHotkey(values, flag: "--set-hotkey")
        command.recordHotkey = try parseHotkey(values, flag: "--set-record-hotkey")
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

    /// `nil` when the flag is absent, `.some(nil)` for `none`.
    private static func parseHotkey(_ values: ArgumentValues, flag: String) throws -> Hotkey?? {
        guard let text = try values.optional(flag) else { return nil }
        if text.lowercased() == "none" { return .some(nil) }
        guard let hotkey = Hotkey(text) else { throw CommandLineError.invalidValue(flag, text) }
        if let problem = hotkey.problem { throw CommandLineError.invalidValue(flag, "\(text): \(problem)") }
        return .some(hotkey)
    }

    /// The settings with the changes applied. Throws when a changed hotkey would duplicate the
    /// other slot's, so a rejected change is never saved.
    public func apply(to settings: CaptureSettings) throws -> CaptureSettings {
        var settings = settings
        if let hotkey { settings.captureHotkey = hotkey }
        if let recordHotkey { settings.recordHotkey = recordHotkey }
        if let target { settings.defaultRequest.target = target }
        if let delaySeconds { settings.defaultRequest.delaySeconds = delaySeconds }
        for (slot, flag) in Self.hotkeyFlags where (slot == .capture ? hotkey : recordHotkey) != nil {
            if let chosen = settings[slot], let problem = settings.problem(with: chosen, for: slot) {
                throw CommandLineError.invalidValue(flag, "\(chosen.display): \(problem)")
            }
        }
        return settings
    }
}
