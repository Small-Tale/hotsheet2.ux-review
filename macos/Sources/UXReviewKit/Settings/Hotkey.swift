import Foundation

/// A global keyboard shortcut: one key plus modifiers. Key codes are macOS virtual key codes
/// (Carbon `kVK_*`), so the app can register the hotkey with `RegisterEventHotKey` directly.
/// Text form: `⌃⌥⇧⌘U` (display) or `ctrl+opt+shift+cmd+u` (also accepted when parsing).
/// Spec: docs/05-start-and-settings.md §5.2.
public struct Hotkey: Equatable, Hashable, Sendable {
    public enum Modifier: String, CaseIterable, Comparable, Sendable {
        // Declared in Apple's display order: ⌃ ⌥ ⇧ ⌘.
        case control, option, shift, command

        public var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }

        /// Carbon modifier mask (`controlKey`, `optionKey`, `shiftKey`, `cmdKey`).
        public var carbonMask: UInt32 {
            switch self {
            case .control: 0x1000
            case .option: 0x0800
            case .shift: 0x0200
            case .command: 0x0100
            }
        }

        static let words: [String: Modifier] = [
            "ctrl": .control, "control": .control, "⌃": .control,
            "opt": .option, "option": .option, "alt": .option, "⌥": .option,
            "shift": .shift, "⇧": .shift,
            "cmd": .command, "command": .command, "⌘": .command,
        ]

        public static func < (lhs: Modifier, rhs: Modifier) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    public var keyCode: UInt32
    public var modifiers: Set<Modifier>

    public init(keyCode: UInt32, modifiers: Set<Modifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌥⇧⌘U: unlikely to clash with system or common app shortcuts.
    public static let defaultCapture = Hotkey(keyCode: 32, modifiers: [.option, .shift, .command])
    /// ⌥⇧⌘V: record a video ("V" for video), next to the capture shortcut.
    public static let defaultRecord = Hotkey(keyCode: 9, modifiers: [.option, .shift, .command])
    /// ⌥⇧⌘E: open the UX Review window ("E" for editor), in the same ⌥⇧⌘ family. Registration is
    /// exclusive, so if another app already owns it Settings says so (docs/05 §5.2).
    public static let defaultOpenReview = Hotkey(keyCode: 14, modifiers: [.option, .shift, .command])

    public var carbonModifiers: UInt32 {
        modifiers.reduce(0) { $0 | $1.carbonMask }
    }

    /// The key's display name, for example `U`, `5`, `F6`, or `Space`; nil for unsupported keys.
    public var keyName: String? { Self.names[keyCode] }

    /// `⌥⇧⌘U`.
    public var display: String {
        modifiers.sorted().map(\.symbol).joined() + (keyName ?? "#\(keyCode)")
    }

    /// Why this combination can't be a global hotkey, or nil when it can.
    public var problem: String? {
        guard keyName != nil else { return "That key can't be used in a shortcut." }
        let isFunctionKey = Self.functionKeys.contains(keyCode)
        if !isFunctionKey, modifiers.isDisjoint(with: [.command, .control, .option]) {
            return "Use at least one of ⌘, ⌃, or ⌥ so the shortcut doesn't block normal typing."
        }
        return nil
    }

    /// Parses `⌥⇧⌘U`, `opt+shift+cmd+u`, or `Ctrl-Opt-F6` (case-insensitive).
    public init?(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespaces)
        var modifiers: Set<Modifier> = []
        // Leading symbols: ⌃⌥⇧⌘.
        while let first = rest.first, let modifier = Modifier.words[String(first)] {
            modifiers.insert(modifier)
            rest.removeFirst()
        }
        // Symbol form: what is left is the key itself (this also covers "-" and "+"-like keys).
        if let code = Self.codes[rest.lowercased()] {
            self.init(keyCode: code, modifiers: modifiers)
            return
        }
        // Word modifiers separated by + or -; the final part is the key. "cmd++" means the + key
        // is unsupported anyway, so splitting on separators is safe.
        let parts = rest.split(whereSeparator: { $0 == "+" || $0 == "-" }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let keyPart = parts.last, !keyPart.isEmpty else { return nil }
        for word in parts.dropLast() {
            guard let modifier = Modifier.words[word] else { return nil }
            modifiers.insert(modifier)
        }
        guard let code = Self.codes[keyPart] else { return nil }
        self.init(keyCode: code, modifiers: modifiers)
    }

    static let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// Supported keys: letters, digits, F1–F12, Space, and common punctuation.
    static let names: [UInt32: String] = {
        var names: [UInt32: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
            45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            49: "Space", 27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
        ]
        let functionCodes: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionCodes.enumerated() {
            names[code] = "F\(index + 1)"
        }
        return names
    }()

    static let codes: [String: UInt32] = Dictionary(names.map { ($1.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
}

extension Hotkey: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let hotkey = Hotkey(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown hotkey \(text)"))
        }
        self = hotkey
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(display)
    }
}
