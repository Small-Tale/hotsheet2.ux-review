import Foundation

/// User settings for starting reviews. Stored as JSON under one defaults key so the whole set
/// changes atomically. Spec: docs/05-start-and-settings.md §5.3.
public struct CaptureSettings: Codable, Equatable, Sendable {
    /// What the global hotkey and "Capture Default" do.
    public var defaultRequest: CaptureRequest
    /// Global hotkey for the default capture; nil disables it.
    public var captureHotkey: Hotkey?

    public init(
        defaultRequest: CaptureRequest = CaptureRequest(kind: .screenshot, target: .region),
        captureHotkey: Hotkey? = .defaultCapture
    ) {
        self.defaultRequest = defaultRequest
        self.captureHotkey = captureHotkey
    }

    private enum CodingKeys: String, CodingKey { case defaultRequest, captureHotkey }

    /// Missing fields take their defaults, so older or partial settings still load. An explicit
    /// `null` hotkey stays disabled.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CaptureSettings()
        defaultRequest = try container.decodeIfPresent(CaptureRequest.self, forKey: .defaultRequest) ?? defaults.defaultRequest
        captureHotkey = container.contains(.captureHotkey)
            ? try container.decodeIfPresent(Hotkey.self, forKey: .captureHotkey)
            : defaults.captureHotkey
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultRequest, forKey: .defaultRequest)
        try container.encode(captureHotkey, forKey: .captureHotkey) // explicit null = disabled
    }
}

/// The slice of `UserDefaults` the settings need, so tests can use an in-memory store.
public protocol KeyValueStoring: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStoring {}

public enum CaptureSettingsStore {
    public static let key = "captureSettings"

    /// The saved settings, or defaults when nothing (or something unreadable) is saved.
    public static func load(from store: KeyValueStoring) -> CaptureSettings {
        guard let data = store.data(forKey: key),
              let settings = try? JSONDecoder().decode(CaptureSettings.self, from: data)
        else { return CaptureSettings() }
        return settings
    }

    public static func save(_ settings: CaptureSettings, to store: KeyValueStoring) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try store.set(encoder.encode(settings), forKey: key)
    }
}

/// What a hotkey press does, given what capture is doing right now.
public enum HotkeyAction: Equatable, Sendable {
    case start(CaptureRequest)
    case cancelCountdown
    case stopRecording
    case ignore

    /// Idle → start the default capture. Counting down → cancel (the HUD can't take Esc).
    /// Recording → stop. Picking, capturing, finishing → ignore (the picker handles Esc itself).
    public static func decide(phase: CapturePhase, settings: CaptureSettings) -> HotkeyAction {
        switch phase {
        case .idle: .start(settings.defaultRequest)
        case .countingDown: .cancelCountdown
        case .recording: .stopRecording
        case .picking, .capturing, .finishing: .ignore
        }
    }
}
