import Foundation

// Platform-neutral descriptions of UX Review's menus: the menu bar (status item) menu and the
// app menu bar's Capture menu. The app turns entries into NSMenu items; tests check the
// structure for every capture phase. Spec: docs/05-start-and-settings.md §5.1.

/// What choosing a menu entry does.
public enum MenuCommand: Hashable, Sendable {
    case capture(CaptureRequest)
    case cancelCapture
    case stopRecording
    /// Flips "Narrate Next Recording with Microphone" (one recording only, docs/04 §4.9).
    case toggleNarration
    case openSettings
    /// Opens (or brings forward) the UX Review window on the current review.
    case openUXReview
    case quit
}

/// A menu key equivalent: one key plus modifiers. `key` is the character the menu shows and
/// matches (lowercase letter, digit, punctuation, or " " for Space).
public struct MenuShortcut: Hashable, Sendable {
    public var key: String
    public var modifiers: Set<Hotkey.Modifier>

    public init(_ key: String, _ modifiers: Set<Hotkey.Modifier> = [.command]) {
        self.key = key
        self.modifiers = modifiers
    }

    /// A global hotkey shown as a menu item's shortcut, when a menu can render its key (letters,
    /// digits, and Space). Other keys still work globally but show no shortcut in the menu.
    public init?(_ hotkey: Hotkey?) {
        guard let hotkey, let name = hotkey.keyName else { return nil }
        if name == "Space" {
            self.init(" ", hotkey.modifiers)
        } else if name.count == 1, let character = name.lowercased().first, character.isLetter || character.isNumber {
            self.init(String(character), hotkey.modifiers)
        } else {
            return nil
        }
    }

    /// `⌥⇧⌘U`.
    public var display: String {
        modifiers.sorted().map(\.symbol).joined() + (key == " " ? "Space" : key.uppercased())
    }
}

/// One button of a `MenuEntry.choices` row.
public struct MenuChoice: Hashable, Sendable {
    public var title: String
    public var command: MenuCommand
    /// Spoken by VoiceOver, for example "Image after 3 seconds".
    public var accessibilityLabel: String

    public init(_ title: String, _ command: MenuCommand, accessibilityLabel: String) {
        self.title = title
        self.command = command
        self.accessibilityLabel = accessibilityLabel
    }
}

public indirect enum MenuEntry: Hashable, Sendable {
    /// Disabled text, such as the app name or a capture status line.
    case label(String)
    case separator
    case action(String, MenuCommand, shortcut: MenuShortcut? = nil)
    case toggle(String, isOn: Bool, MenuCommand)
    case submenu(String, [MenuEntry])
    /// A titled row of buttons (a segmented control in AppKit): "Delayed  [3 s | 10 s]".
    case choices(String, [MenuChoice])

    public var title: String? {
        switch self {
        case let .label(title), let .action(title, _, _), let .toggle(title, _, _), let .submenu(title, _),
             let .choices(title, _): title
        case .separator: nil
        }
    }
}

/// What the menus need to know about the app right now.
public struct MenuState: Equatable, Sendable {
    public var phase: CapturePhase
    public var settings: CaptureSettings
    /// The narration checkbox: the Settings default unless changed for the next recording.
    public var narratesNextRecording: Bool
    /// Whether the recording in progress includes narration.
    public var recordingNarration: Bool
    /// Registered global hotkeys (shown next to the items they trigger).
    public var hotkeys: [HotkeySlot: Hotkey]
    public var version: String
    /// When the menu opens (for the elapsed recording time).
    public var now: Date

    public init(
        phase: CapturePhase = .idle,
        settings: CaptureSettings = CaptureSettings(),
        narratesNextRecording: Bool = false,
        recordingNarration: Bool = false,
        hotkeys: [HotkeySlot: Hotkey] = [:],
        version: String = "1.0",
        now: Date = Date()
    ) {
        self.phase = phase
        self.settings = settings
        self.narratesNextRecording = narratesNextRecording
        self.recordingNarration = recordingNarration
        self.hotkeys = hotkeys
        self.version = version
        self.now = now
    }

    /// The hotkey shortcut to show next to an item that starts `request`: the capture hotkey
    /// when it starts exactly that request, else the record hotkey when it does.
    func shortcut(for request: CaptureRequest) -> MenuShortcut? {
        for slot in HotkeySlot.allCases where slot.request(in: settings) == request {
            if let shortcut = MenuShortcut(hotkeys[slot]) { return shortcut }
        }
        return nil
    }
}

public enum AppMenus {
    /// Delays offered in the menu bar menu's "Delayed" rows (docs/05 §5.1).
    public static let statusDelays = [3, 10]

    /// The menu bar menu:
    ///
    ///     UX Review 1.0
    ///     ───
    ///     Capture Image ▸   Immediate / Delayed [3 s | 10 s]
    ///     Capture Video ▸   Immediate / Delayed [3 s | 10 s] / ─ / Narrate Next Recording
    ///     ───
    ///     Settings…  ⌘,
    ///     Open UX Review
    ///     ───
    ///     Quit UX Review  ⌘Q
    ///
    /// While a capture runs, the two capture submenus are replaced by what stops or explains it.
    public static func statusMenu(_ state: MenuState) -> [MenuEntry] {
        var entries: [MenuEntry] = [.label("UX Review \(state.version)"), .separator]
        if let running = runningCapture(state) {
            entries += running
        } else {
            entries.append(.submenu("Capture Image", quickCapture(.screenshot, state)))
            entries.append(.submenu("Capture Video", quickCapture(.video, state)))
        }
        entries += [
            .separator,
            .action("Settings…", .openSettings, shortcut: MenuShortcut(",")),
            .action("Open UX Review", .openUXReview, shortcut: MenuShortcut(state.hotkeys[.openReview])),
            .separator,
            .action("Quit UX Review", .quit, shortcut: MenuShortcut("q")),
        ]
        return entries
    }

    /// The app menu bar's Capture menu (shown while a UX Review window is open): every target,
    /// with every delay preset, so the full choice the menu bar menu leaves out is one click away.
    public static func captureMenu(_ state: MenuState) -> [MenuEntry] {
        if let running = runningCapture(state) { return running }
        var entries: [MenuEntry] = []
        for (kind, title) in [(CaptureKind.screenshot, "Screenshot"), (.video, "Record Video")] {
            if !entries.isEmpty { entries.append(.separator) }
            for target in CaptureTarget.allCases {
                let request = CaptureRequest(kind: kind, target: target)
                entries.append(.action("\(title) of \(target.label)", .capture(request), shortcut: state.shortcut(for: request)))
            }
            let delayed: [MenuEntry] = CaptureRequest.delayPresets.filter { $0 > 0 }.flatMap { delay in
                CaptureTarget.allCases.map { target in
                    MenuEntry.action(
                        "\(target.label) after \(delay) s",
                        .capture(CaptureRequest(kind: kind, target: target, delaySeconds: delay)),
                        shortcut: state.shortcut(for: CaptureRequest(kind: kind, target: target, delaySeconds: delay))
                    )
                }
            }
            entries.append(.submenu("\(title) After Delay", delayed))
        }
        entries += [.separator, narrationToggle(state)]
        return entries
    }

    /// "Immediate" and "Delayed [3 s | 10 s]" for the default target (Settings), plus the
    /// narration checkbox for video.
    static func quickCapture(_ kind: CaptureKind, _ state: MenuState) -> [MenuEntry] {
        let target = state.settings.defaultRequest.target
        let now = CaptureRequest(kind: kind, target: target)
        let noun = kind == .screenshot ? "Image" : "Video"
        var entries: [MenuEntry] = [
            .label("\(noun) of \(target.label)"),
            .action("Immediate", .capture(now), shortcut: state.shortcut(for: now)),
            .choices("Delayed", statusDelays.map { delay in
                MenuChoice(
                    "\(delay) s",
                    .capture(CaptureRequest(kind: kind, target: target, delaySeconds: delay)),
                    accessibilityLabel: "\(noun) of \(target.label) after \(delay) seconds"
                )
            }),
        ]
        if kind == .video {
            entries += [.separator, narrationToggle(state)]
        }
        return entries
    }

    static func narrationToggle(_ state: MenuState) -> MenuEntry {
        .toggle("Narrate Next Recording with Microphone", isOn: state.narratesNextRecording, .toggleNarration)
    }

    /// What replaces the capture items while a capture runs; nil when idle.
    static func runningCapture(_ state: MenuState) -> [MenuEntry]? {
        switch state.phase {
        case .idle:
            return nil
        case let .countingDown(_, remaining):
            return [.action("Cancel Capture (\(remaining) s)", .cancelCapture)]
        case .picking:
            return [.label("Choosing what to capture… (Esc cancels)")]
        case .capturing:
            return [.label("Capturing…")]
        case let .recording(startedAt):
            let elapsed = Int(state.now.timeIntervalSince(startedAt) * 1000)
            var entries: [MenuEntry] = [.action("Stop Recording (\(clock(elapsed)))", .stopRecording)]
            if state.recordingNarration { entries.append(.label("Recording microphone narration")) }
            return entries
        case .finishing:
            return [.label("Saving recording…")]
        }
    }

    /// `m:ss`.
    public static func clock(_ milliseconds: Int) -> String {
        let milliseconds = max(milliseconds, 0)
        return String(format: "%d:%02d", milliseconds / 60000, (milliseconds / 1000) % 60)
    }
}

/// Whether UX Review shows a Dock icon and app menu bar: only while one of its windows
/// (editor, Submit Review, Draft Reviews, Settings) is open, minimized ones included. Capture
/// overlays, HUDs, and alerts don't count. Spec: docs/05-start-and-settings.md §5.1.1.
public struct WindowPresence: Equatable, Sendable {
    public enum Policy: Equatable, Sendable {
        /// Dock icon, ⌘-Tab, and the app menu bar.
        case regular
        /// Menu bar icon only.
        case accessory
    }

    public private(set) var open: Set<String> = []

    public init() {}

    /// Returns true when the policy changed.
    @discardableResult
    public mutating func opened(_ id: String) -> Bool {
        let before = policy
        open.insert(id)
        return policy != before
    }

    @discardableResult
    public mutating func closed(_ id: String) -> Bool {
        let before = policy
        open.remove(id)
        return policy != before
    }

    public var policy: Policy { open.isEmpty ? .accessory : .regular }
}
