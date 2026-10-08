import Testing
@testable import UXReviewKit

/// Switching what is picked from inside the picker (HS2-8NATQR, docs/04 §4.2): the key × mode ×
/// dragging matrix, and realistic sequences of presses.
struct PickerKeysTests {
    @Test func keyCodes() {
        #expect(PickerKeys.Key(keyCode: 49) == .space)
        #expect(PickerKeys.Key(keyCode: 36) == .returnKey && PickerKeys.Key(keyCode: 76) == .returnKey)
        #expect(PickerKeys.Key(keyCode: 53) == .escape)
        #expect(PickerKeys.Key(keyCode: 0) == .other)
    }

    @Test(arguments: [CaptureTarget.region, .window, .display], [false, true])
    func matrix(mode: CaptureTarget, dragging: Bool) {
        #expect(PickerKeys.action(for: .escape, mode: mode, dragging: dragging) == .cancel)
        #expect(PickerKeys.action(for: .returnKey, mode: mode, dragging: dragging) == .pickDisplay)
        #expect(PickerKeys.action(for: .other, mode: mode, dragging: dragging) == PickerKeys.Action.none)
        let space = PickerKeys.action(for: .space, mode: mode, dragging: dragging)
        switch mode {
        case .region: #expect(space == (dragging ? PickerKeys.Action.none : .switchMode(.window)))
        case .window: #expect(space == .switchMode(.region))
        case .display: #expect(space == PickerKeys.Action.none)
        }
    }

    /// Space, Space, Space alternates; a drag blocks the switch until it ends; Return then picks
    /// the display whichever mode is showing.
    @Test func sequences() {
        var mode = CaptureTarget.region
        func press(_ key: PickerKeys.Key, dragging: Bool = false) -> PickerKeys.Action {
            let action = PickerKeys.action(for: key, mode: mode, dragging: dragging)
            if case let .switchMode(next) = action { mode = next }
            return action
        }
        #expect(press(.space) == .switchMode(.window))
        #expect(press(.space) == .switchMode(.region))
        #expect(press(.space, dragging: true) == PickerKeys.Action.none)
        #expect(mode == .region)
        #expect(press(.space) == .switchMode(.window))
        #expect(press(.returnKey) == .pickDisplay)
    }

    @Test func hintsNameTheKeys() {
        #expect(PickerKeys.hint(for: .region) == "Drag to select a region · Space: window · Return: whole screen · Esc to cancel")
        #expect(PickerKeys.hint(for: .window).hasPrefix("Click a window to capture it · Space: region"))
        #expect(PickerKeys.hint(for: .display).contains("Return: whole screen"))
    }
}
