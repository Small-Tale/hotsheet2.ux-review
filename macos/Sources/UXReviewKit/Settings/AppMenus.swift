import Foundation

// Platform-neutral descriptions of UX Review's menus: the menu bar (status item) menu and the
// app menu bar's Capture menu. The app turns entries into NSMenu items; tests check the
// structure for every capture phase. Spec: docs/05-start-and-settings.md §5.1.

/// What choosing a menu entry does.
public enum MenuCommand: Hashable, Sendable {
    case capture(CaptureRequest)
    /// Captures `kind` with the default target and delay as they are when chosen, so a picker
    /// change in the still-open menu bar menu applies (docs/05 §5.1).
    case captureDefault(CaptureKind)
    /// Makes `target` the default capture target (Settings › Default capture, docs/05 §5.3).
    case setCaptureTarget(CaptureTarget)
    /// Makes `seconds` the default capture delay (Settings › Default capture, docs/05 §5.3).
    case setCaptureDelay(Int)
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
    /// A titled row of mutually exclusive options with one selected (a select-one segmented
    /// control): "Capture  [Screen | Window | Region]". Choosing one runs it and keeps the menu
    /// open, so the reviewer can go on to a capture item.
    case picker(String, [MenuChoice], selected: Int?)

    public var title: String? {
        switch self {
        case let .label(title), let .action(title, _, _), let .toggle(title, _, _), let .submenu(title, _),
             let .picker(title, _, _): title
        case .separator: nil
        }
    }
}

/// Where a menu row's own drawing (a picker row's title and control) must go to line up with
/// the items AppKit draws. Measured on macOS 26 menus (`HS2-T4RS7M`): titles start 16 pt from
/// the menu's edge, or 30 pt when the menu shows a checkmark column because one of its items is
/// checked; shortcuts end 18 pt from the right edge.
public enum MenuMetrics {
    public static let titleInset = 16.0
    public static let checkmarkColumnWidth = 14.0
    public static let trailingInset = 18.0

    /// The title inset for a row among `siblings` (the entries of the same menu level).
    public static func titleInset(among siblings: [MenuEntry]) -> Double {
        showsCheckmarkColumn(siblings) ? titleInset + checkmarkColumnWidth : titleInset
    }

    /// Whether AppKit draws a checkmark column: some item at this level is checked.
    public static func showsCheckmarkColumn(_ siblings: [MenuEntry]) -> Bool {
        siblings.contains { if case .toggle(_, true, _) = $0 { true } else { false } }
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
    /// Delays offered in the menu bar menu's "Delay" row (docs/05 §5.1); 0 is "None".
    public static let statusDelays = [0, 3, 10]

    /// The menu bar menu:
    ///
    ///     UX Review 1.0
    ///     ───
    ///     Capture  [Screen | Window | Region]
    ///     Delay    [None | 3 s | 10 s]
    ///     Capture Image                       ⌥⇧⌘U
    ///     Capture Video                       ⌥⇧⌘V
    ///     Narrate Next Recording with Microphone
    ///     ───
    ///     Settings…  ⌘,
    ///     Open UX Review
    ///     ───
    ///     Quit UX Review  ⌘Q
    ///
    /// While a capture runs, the rows from Capture to Narrate are replaced by what stops or
    /// explains it.
    public static func statusMenu(_ state: MenuState) -> [MenuEntry] {
        var entries: [MenuEntry] = [.label("UX Review \(state.version)"), .separator]
        if let running = runningCapture(state) {
            entries += running
        } else {
            let request = state.settings.defaultRequest
            entries += [
                targetPicker(state),
                delayPicker(state),
                .action("Capture Image", .captureDefault(.screenshot), shortcut: state.shortcut(for: request.with(kind: .screenshot))),
                .action("Capture Video", .captureDefault(.video), shortcut: state.shortcut(for: request.with(kind: .video))),
                narrationToggle(state),
            ]
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

    /// "Capture [Screen | Window | Region]": the default target (Settings), which Capture Image
    /// and Capture Video use. Choosing a segment changes that setting (`HS2-W62GWS`).
    static func targetPicker(_ state: MenuState) -> MenuEntry {
        let targets = CaptureTarget.allCases
        return .picker(
            "Capture",
            targets.map { MenuChoice($0.label, .setCaptureTarget($0), accessibilityLabel: "Capture \($0.label)") },
            selected: targets.firstIndex(of: state.settings.defaultRequest.target)
        )
    }

    /// "Delay [None | 3 s | 10 s]": the default delay (Settings), which Capture Image and Capture
    /// Video use. Choosing a segment changes that setting (`HS2-WC6JSH`). A default the row
    /// doesn't offer (5 s, set in Settings) shows as its own segment, so the row always says
    /// what Capture Image will do.
    static func delayPicker(_ state: MenuState) -> MenuEntry {
        let current = state.settings.defaultRequest.delaySeconds
        let delays = statusDelays.contains(current) ? statusDelays : (statusDelays + [current]).sorted()
        return .picker(
            "Delay",
            delays.map { delay in
                delay == 0
                    ? MenuChoice("None", .setCaptureDelay(0), accessibilityLabel: "No delay")
                    : MenuChoice("\(delay) s", .setCaptureDelay(delay), accessibilityLabel: "Delay \(delay) seconds")
            },
            selected: delays.firstIndex(of: current)
        )
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
