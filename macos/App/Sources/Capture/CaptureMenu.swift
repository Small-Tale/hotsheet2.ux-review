import SwiftUI
import UXReviewKit

/// Capture commands in the menu bar menu. Spec: docs/04-capture.md §4.1.
struct CaptureMenuSection: View {
    @ObservedObject var capture: CaptureCoordinator
    @ObservedObject var settings: SettingsModel

    var body: some View {
        switch capture.phase {
        case .idle:
            defaultCaptureButton
            Divider()
            ForEach(CaptureTarget.allCases, id: \.self) { target in
                Button("Screenshot of \(target.label)") { capture.screenshot(CaptureRequest(kind: .screenshot, target: target)) }
            }
            Menu("Screenshot After Delay") {
                ForEach(CaptureRequest.delayPresets.filter { $0 > 0 }, id: \.self) { delay in
                    Section("\(delay) seconds") {
                        ForEach(CaptureTarget.allCases, id: \.self) { target in
                            Button("\(target.label) after \(delay) s") {
                                capture.screenshot(CaptureRequest(kind: .screenshot, target: target, delaySeconds: delay))
                            }
                        }
                    }
                }
            }
        case let .countingDown(seconds):
            Button("Cancel Capture (\(seconds) s)") { capture.cancel() }
        case .picking:
            Text("Choosing what to capture… (Esc cancels)")
        case .capturing:
            Text("Capturing…")
        }
        Divider()
        if let last = capture.lastCapture {
            Text("Current review: \(last.draft.bundle.media.count) capture(s), last \(last.media.filename)")
        }
        Button("Show Current Review in Finder") { capture.revealCurrentReview() }
        Button("Start New Review") { capture.startNewReview() }
    }

    /// "Capture Screenshot of Region   ⌥⇧⌘U": the default capture, showing the global shortcut.
    @ViewBuilder private var defaultCaptureButton: some View {
        let request = settings.settings.defaultRequest
        let button = Button("Capture \(request.summary)") { capture.start(request) }
        if let hotkey = settings.settings.captureHotkey, case .registered = settings.registration,
           let shortcut = KeyboardShortcut(hotkey) {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }
}

extension KeyboardShortcut {
    /// The menu's rendering of a global hotkey (letters, digits, and Space only; others show no
    /// shortcut in the menu but still work globally).
    init?(_ hotkey: Hotkey) {
        guard let name = hotkey.keyName else { return nil }
        let key: KeyEquivalent
        if name == "Space" {
            key = .space
        } else if name.count == 1, let character = name.lowercased().first, character.isLetter || character.isNumber {
            key = KeyEquivalent(character)
        } else {
            return nil
        }
        var modifiers: EventModifiers = []
        if hotkey.modifiers.contains(.control) { modifiers.insert(.control) }
        if hotkey.modifiers.contains(.option) { modifiers.insert(.option) }
        if hotkey.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if hotkey.modifiers.contains(.command) { modifiers.insert(.command) }
        self.init(key, modifiers: modifiers)
    }
}
