import Foundation

/// User settings for starting reviews. Stored as JSON under one defaults key so the whole set
/// changes atomically. Spec: docs/05-start-and-settings.md §5.3.
public struct CaptureSettings: Codable, Equatable, Sendable {
    /// What the global hotkey and "Capture Default" do.
    public var defaultRequest: CaptureRequest
    /// Global hotkey for the default capture; nil disables it.
    public var captureHotkey: Hotkey?
    /// Global hotkey that records a video of the default target; nil disables it.
    public var recordHotkey: Hotkey?
    /// Global hotkey that opens the UX Review window; nil disables it.
    public var openReviewHotkey: Hotkey?
    /// Whether recordings include microphone narration by default (off). The menu can change it
    /// for the next recording only. Spec: docs/04-capture.md §4.9.
    public var narration: Bool
    /// Whether recordings show the mouse pointer (on). Screenshots never do. Spec:
    /// docs/04-capture.md §4.9.
    public var showPointerInRecordings: Bool
    /// Whether recordings draw a ring at each mouse click, like QuickTime Player (off).
    public var showClicksInRecordings: Bool
    /// Whether images and videos are scaled down for the target project's AI tool when filed
    /// (on). The draft keeps full-size files. Spec: docs/07-review-session.md §7.5.1.
    public var downscaleForAI: Bool
    /// Whether the annotation editor opens on each new capture (on, `HS2-WNZVXR`). Spec:
    /// docs/04-capture.md §4.6.
    public var openEditorAfterCapture: Bool

    public init(
        defaultRequest: CaptureRequest = CaptureRequest(kind: .screenshot, target: .region),
        captureHotkey: Hotkey? = .defaultCapture,
        recordHotkey: Hotkey? = .defaultRecord,
        openReviewHotkey: Hotkey? = .defaultOpenReview,
        narration: Bool = false,
        showPointerInRecordings: Bool = true,
        showClicksInRecordings: Bool = false,
        downscaleForAI: Bool = true,
        openEditorAfterCapture: Bool = true
    ) {
        self.defaultRequest = defaultRequest
        self.captureHotkey = captureHotkey
        self.recordHotkey = recordHotkey
        self.openReviewHotkey = openReviewHotkey
        self.narration = narration
        self.showPointerInRecordings = showPointerInRecordings
        self.showClicksInRecordings = showClicksInRecordings
        self.downscaleForAI = downscaleForAI
        self.openEditorAfterCapture = openEditorAfterCapture
    }

    /// How recordings show the pointer, per these settings.
    public var recordingPointer: RecordingPointer {
        RecordingPointer(showsPointer: showPointerInRecordings, showsClicks: showClicksInRecordings)
    }

    public subscript(slot: HotkeySlot) -> Hotkey? {
        get {
            switch slot {
            case .capture: captureHotkey
            case .record: recordHotkey
            case .openReview: openReviewHotkey
            }
        }
        set {
            switch slot {
            case .capture: captureHotkey = newValue
            case .record: recordHotkey = newValue
            case .openReview: openReviewHotkey = newValue
            }
        }
    }

    /// Why `hotkey` can't be used for `slot`: unusable on its own, or already the other slot's.
    public func problem(with hotkey: Hotkey, for slot: HotkeySlot) -> String? {
        if let problem = hotkey.problem { return problem }
        for other in HotkeySlot.allCases where other != slot && self[other] == hotkey {
            return "\(hotkey.display) is already the \(other.shortcutName) shortcut."
        }
        return nil
    }

    /// The hotkey to register for `slot`: nil when disabled, or when it duplicates an earlier
    /// slot's (possible only in hand-edited settings; the earlier slot keeps it).
    public func registrable(_ slot: HotkeySlot) -> Hotkey? {
        guard let hotkey = self[slot] else { return nil }
        let earlier = HotkeySlot.allCases.prefix { $0 != slot }
        return earlier.contains { self[$0] == hotkey } ? nil : hotkey
    }

    private enum CodingKeys: String, CodingKey {
        case defaultRequest, captureHotkey, recordHotkey, openReviewHotkey, narration
        case showPointerInRecordings, showClicksInRecordings, downscaleForAI, openEditorAfterCapture
    }

    /// Missing fields take their defaults, so older or partial settings still load. An explicit
    /// `null` hotkey stays disabled.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CaptureSettings()
        defaultRequest = try container.decodeIfPresent(CaptureRequest.self, forKey: .defaultRequest) ?? defaults.defaultRequest
        captureHotkey = container.contains(.captureHotkey)
            ? try container.decodeIfPresent(Hotkey.self, forKey: .captureHotkey)
            : defaults.captureHotkey
        recordHotkey = container.contains(.recordHotkey)
            ? try container.decodeIfPresent(Hotkey.self, forKey: .recordHotkey)
            : defaults.recordHotkey
        openReviewHotkey = container.contains(.openReviewHotkey)
            ? try container.decodeIfPresent(Hotkey.self, forKey: .openReviewHotkey)
            : defaults.openReviewHotkey
        narration = try container.decodeIfPresent(Bool.self, forKey: .narration) ?? defaults.narration
        showPointerInRecordings = try container.decodeIfPresent(Bool.self, forKey: .showPointerInRecordings)
            ?? defaults.showPointerInRecordings
        showClicksInRecordings = try container.decodeIfPresent(Bool.self, forKey: .showClicksInRecordings)
            ?? defaults.showClicksInRecordings
        downscaleForAI = try container.decodeIfPresent(Bool.self, forKey: .downscaleForAI) ?? defaults.downscaleForAI
        openEditorAfterCapture = try container.decodeIfPresent(Bool.self, forKey: .openEditorAfterCapture)
            ?? defaults.openEditorAfterCapture
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultRequest, forKey: .defaultRequest)
        try container.encode(captureHotkey, forKey: .captureHotkey) // explicit null = disabled
        try container.encode(recordHotkey, forKey: .recordHotkey)
        try container.encode(openReviewHotkey, forKey: .openReviewHotkey)
        try container.encode(narration, forKey: .narration)
        try container.encode(showPointerInRecordings, forKey: .showPointerInRecordings)
        try container.encode(showClicksInRecordings, forKey: .showClicksInRecordings)
        try container.encode(downscaleForAI, forKey: .downscaleForAI)
        try container.encode(openEditorAfterCapture, forKey: .openEditorAfterCapture)
    }
}

/// How a recording shows the mouse pointer: ScreenCaptureKit's `showsCursor` and
/// `showMouseClicks`. The two are independent, so clicks can be shown without the pointer.
/// Spec: docs/04-capture.md §4.9.
public struct RecordingPointer: Codable, Equatable, Sendable {
    public var showsPointer: Bool
    public var showsClicks: Bool

    public init(showsPointer: Bool = true, showsClicks: Bool = false) {
        self.showsPointer = showsPointer
        self.showsClicks = showsClicks
    }
}

/// The global hotkeys UX Review registers. Spec: docs/05-start-and-settings.md §5.2.
public enum HotkeySlot: String, CaseIterable, Codable, Sendable {
    /// Starts the default capture (screenshot or video, per Settings).
    case capture
    /// Records a video of the default target, whatever the default kind is.
    case record
    /// Opens the UX Review window on the current review (`HS2-KVMX71`).
    case openReview

    public var title: String {
        switch self {
        case .capture: "Capture"
        case .record: "Record video"
        case .openReview: "Open UX Review"
        }
    }

    /// How messages name this slot's shortcut: "the capture shortcut".
    public var shortcutName: String {
        switch self {
        case .capture: "capture"
        case .record: "record video"
        case .openReview: "Open UX Review"
        }
    }

    /// The Settings row's label.
    public var settingsLabel: String {
        switch self {
        case .capture: "Start default capture"
        case .record: "Record video"
        case .openReview: "Open UX Review"
        }
    }

    /// Carbon `EventHotKeyID.id` for this slot (nonzero, stable).
    public var carbonID: UInt32 {
        switch self {
        case .capture: 1
        case .record: 2
        case .openReview: 3
        }
    }

    public init?(carbonID: UInt32) {
        guard let slot = Self.allCases.first(where: { $0.carbonID == carbonID }) else { return nil }
        self = slot
    }

    /// The capture pressing this slot's hotkey starts when idle; nil for Open UX Review.
    public func request(in settings: CaptureSettings) -> CaptureRequest? {
        switch self {
        case .capture: settings.defaultRequest
        case .record: settings.defaultRequest.with(kind: .video)
        case .openReview: nil
        }
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
    /// Open (or bring forward) the UX Review window.
    case openReview
    case ignore

    /// Idle → start the slot's capture. Counting down → cancel (the HUD can't take Esc).
    /// Recording → stop. Picking, capturing, finishing → ignore (the picker handles Esc itself).
    /// Both capture slots cancel and stop, so either hotkey ends what the other started.
    /// Open UX Review opens the window when idle or recording (it never stops a recording), and
    /// is ignored while a capture is being set up or taken, so the window can't land in it.
    public static func decide(phase: CapturePhase, settings: CaptureSettings, slot: HotkeySlot = .capture) -> HotkeyAction {
        guard let request = slot.request(in: settings) else {
            switch phase {
            case .idle, .recording: return .openReview
            case .picking, .countingDown, .capturing, .finishing: return .ignore
            }
        }
        return switch phase {
        case .idle: .start(request)
        case .countingDown: .cancelCountdown
        case .recording: .stopRecording
        case .picking, .capturing, .finishing: .ignore
        }
    }
}
