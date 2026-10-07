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
            captureItems(.screenshot, title: "Screenshot", delayedTitle: "Screenshot After Delay")
            Divider()
            captureItems(.video, title: "Record Video", delayedTitle: "Record Video After Delay")
            // Applies to the next recording only; Settings holds the default (docs/04 §4.9).
            Toggle("Narrate Next Recording with Microphone", isOn: Binding(
                get: { capture.narrationChoice ?? settings.settings.narration },
                set: { capture.narrationChoice = $0 == settings.settings.narration ? nil : $0 }
            ))
        case let .countingDown(_, remaining):
            Button("Cancel Capture (\(remaining) s)") { capture.cancel() }
        case .picking:
            Text("Choosing what to capture… (Esc cancels)")
        case .capturing:
            Text("Capturing…")
        case let .recording(startedAt):
            // The menu is rebuilt each time it opens, so the elapsed time is current then.
            Button("Stop Recording (\(CaptureCoordinator.clock(Int(Date().timeIntervalSince(startedAt) * 1000))))") {
                capture.stopRecording()
            }
            if capture.recordingNarration {
                Text("Recording microphone narration")
            }
        case .finishing:
            Text("Saving recording…")
        }
        Divider()
        if let last = capture.lastCapture {
            Text("Current review: \(last.draft.bundle.media.count) capture(s), last \(last.media.filename)")
        }
        Button("Annotate Current Review…") { capture.annotateCurrentReview() }
            .keyboardShortcut("e")
            .disabled(!capture.hasCurrentReview)
        Button("Open Media for Annotation…") { capture.openMediaForAnnotation() }
            .keyboardShortcut("o")
        Button("Show Current Review in Finder") { capture.revealCurrentReview() }
        Button("Start New Review") { capture.startNewReview() }
    }

    /// "Screenshot of Screen / Window / Region" plus a submenu of the delay presets.
    @ViewBuilder private func captureItems(_ kind: CaptureKind, title: String, delayedTitle: String) -> some View {
        ForEach(CaptureTarget.allCases, id: \.self) { target in
            let request = CaptureRequest(kind: kind, target: target)
            let button = Button("\(title) of \(target.label)") { capture.start(request) }
            // The item the record-video hotkey matches (default target, and only when there is no default delay).
            if kind == .video, request == HotkeySlot.record.request(in: settings.settings) {
                button.globalShortcut(settings.activeHotkey(.record))
            } else {
                button
            }
        }
        Menu(delayedTitle) {
            ForEach(CaptureRequest.delayPresets.filter { $0 > 0 }, id: \.self) { delay in
                Section("\(delay) seconds") {
                    ForEach(CaptureTarget.allCases, id: \.self) { target in
                        Button("\(target.label) after \(delay) s") {
                            capture.start(CaptureRequest(kind: kind, target: target, delaySeconds: delay))
                        }
                    }
                }
            }
        }
    }

    /// "Capture Screenshot of Region   ⌥⇧⌘U": the default capture, showing the global shortcut.
    @ViewBuilder private var defaultCaptureButton: some View {
        let request = settings.settings.defaultRequest
        Button("Capture \(request.summary)") { capture.start(request) }
            .globalShortcut(settings.activeHotkey(.capture))
    }
}

extension View {
    /// Shows a registered global hotkey as the menu item's shortcut, when the menu can render it.
    @ViewBuilder func globalShortcut(_ hotkey: Hotkey?) -> some View {
        if let hotkey, let shortcut = KeyboardShortcut(hotkey) {
            keyboardShortcut(shortcut)
        } else {
            self
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
