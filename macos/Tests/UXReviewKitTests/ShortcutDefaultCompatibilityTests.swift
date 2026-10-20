import Foundation
import Testing
@testable import UXReviewKit

struct ShortcutDefaultCompatibilityTests {
    /// HS2-NJEEAZ: new defaults must preserve explicitly saved previous bindings.
    @Test func preservesSavedCaptureAndVideoBindings() {
        let store = MemoryStore()
        let json = #"{"captureHotkey":"⌥⇧⌘U","recordHotkey":"⌥⇧⌘V"}"#
        store.set(Data(json.utf8), forKey: CaptureSettingsStore.key)
        let loaded = CaptureSettingsStore.load(from: store)
        #expect(loaded.captureHotkey == Hotkey("⌥⇧⌘U"))
        #expect(loaded.recordHotkey == Hotkey("⌥⇧⌘V"))
    }
}
