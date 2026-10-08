import Foundation

/// Keys in the region / window picker (docs/04-capture.md §4.2, HS2-8NATQR): switch what is being
/// picked without opening a window, like macOS ⌘⇧4. Space toggles region ⇄ window, Return takes
/// the whole display under the pointer, Esc cancels.
public enum PickerKeys {
    public enum Key: Equatable, Sendable {
        case space, returnKey, escape, other

        /// The key for a virtual key code (49 Space, 36 Return, 76 keypad Enter, 53 Esc).
        public init(keyCode: UInt16) {
            switch keyCode {
            case 49: self = .space
            case 36, 76: self = .returnKey
            case 53: self = .escape
            default: self = .other
            }
        }
    }

    public enum Action: Equatable, Sendable {
        /// Not a picker key: pass it on.
        case none
        /// Keep picking, now in this mode.
        case switchMode(CaptureTarget)
        /// Capture the whole display under the pointer.
        case pickDisplay
        case cancel
    }

    /// What `key` does in `mode`. Space is ignored while a region is being dragged, so a stray
    /// press never drops the drag; Return and Esc always apply.
    public static func action(for key: Key, mode: CaptureTarget, dragging: Bool) -> Action {
        switch key {
        case .escape: .cancel
        case .returnKey: .pickDisplay
        case .space:
            switch mode {
            case .region: dragging ? .none : .switchMode(.window)
            case .window: .switchMode(.region)
            case .display: .none
            }
        case .other: .none
        }
    }

    /// The hint shown before anything is selected.
    public static func hint(for mode: CaptureTarget) -> String {
        switch mode {
        case .region: "Drag to select a region · Space: window · Return: whole screen · Esc to cancel"
        case .window: "Click a window to capture it · Space: region · Return: whole screen · Esc to cancel"
        case .display: "Return: whole screen · Esc to cancel"
        }
    }
}
