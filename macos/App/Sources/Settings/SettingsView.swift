import AppKit
import SwiftUI
import UXReviewKit

/// The Settings window: what the default capture is and which global shortcuts start captures.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Default capture") {
                Picker("Kind", selection: binding(\.defaultRequest.kind)) {
                    Text("Screenshot").tag(CaptureKind.screenshot)
                    Text("Video").tag(CaptureKind.video)
                }
                Picker("Capture", selection: binding(\.defaultRequest.target)) {
                    ForEach(CaptureTarget.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Delay", selection: binding(\.defaultRequest.delaySeconds)) {
                    ForEach(CaptureRequest.delayPresets, id: \.self) { Text($0 == 0 ? "None" : "\($0) seconds").tag($0) }
                }
                Text(defaultCaptureCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Open the editor after each capture", isOn: binding(\.openEditorAfterCapture))
                Text("Shows the new capture in the annotation editor right away. Off, captures collect in the review quietly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Video") {
                Toggle("Record microphone narration", isOn: binding(\.narration))
                Text("Adds your voice to recordings. Change it for one recording from the Capture Video menu. Needs Microphone permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show pointer in recordings", isOn: binding(\.showPointerInRecordings))
                Toggle("Show clicks in recordings", isOn: binding(\.showClicksInRecordings))
                Text("Clicks show as a ring where you click, like QuickTime Player. Screenshots never include the pointer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Submitting") {
                Toggle("Downscale images and videos for AI", isOn: binding(\.downscaleForAI))
                Text(Self.downscaleCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Global shortcuts") {
                ForEach(HotkeySlot.allCases, id: \.self) { slot in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(slot.settingsLabel) {
                            ShortcutRecorder(model: model, slot: slot)
                        }
                        // Color only the icon; caption text stays legible in light and dark mode.
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: Self.statusSymbol(model.registration(slot)))
                                .foregroundStyle(Self.statusColor(model.registration(slot)))
                            Text(model.registration(slot).message(for: slot)).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                Text("The capture and record shortcuts also cancel a countdown or stop a recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Under Downscale for AI (docs/07 §7.5.1).
    static let downscaleCaption = "Filed captures are scaled down to a size the project's default AI tool reads well "
        + "(Claude, Codex), or 2048 pixels on the longest side. Your draft keeps the full-size files."

    private var defaultCaptureCaption: String {
        "The capture shortcut starts this capture; Record video uses the same target and delay. "
            + "Capture Image and Capture Video in the menu bar menu use this target."
    }

    private static func statusSymbol(_ registration: GlobalHotkeyCenter.Registration) -> String {
        switch registration {
        case .registered: "checkmark.circle.fill"
        case .disabled: "minus.circle"
        default: "exclamationmark.triangle.fill"
        }
    }

    private static func statusColor(_ registration: GlobalHotkeyCenter.Registration) -> Color {
        switch registration {
        case .registered: .green
        case .disabled: .secondary
        default: .orange
        }
    }

    /// The binding each control edits through (`SettingsModel.update`); the downscale wiring
    /// probe flips the Downscale for AI toggle through it too (HS2-ZMDH5D).
    func binding<Value>(_ path: WritableKeyPath<CaptureSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: path] }, set: { value in model.update { $0[keyPath: path] = value } })
    }
}

/// Click, then press the new shortcut. Esc cancels; Delete clears the shortcut. A combination
/// the other slot already uses beeps and explains, like any other unusable one.
struct ShortcutRecorder: View {
    @ObservedObject var model: SettingsModel
    let slot: HotkeySlot
    @State private var recording = false
    @State private var problem: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(recording ? "Press shortcut…" : model.settings[slot]?.display ?? "None")
                    .font(.body.monospaced())
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if model.settings[slot] != nil, !recording {
                Button("Clear") { model.update { $0[slot] = nil } }
            }
        }
        .help(problem ?? "Click, then press a key combination. Esc cancels; Delete clears.")
        .onDisappear(perform: stop)
    }

    private func toggle() {
        if recording { stop() } else { start() }
    }

    private func start() {
        problem = nil
        recording = true
        model.suspendHotkeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { model.resumeHotkeys() }
        recording = false
    }

    private func handle(_ event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            stop()
        case 51, 117: // Delete, Forward Delete
            stop()
            model.update { $0[slot] = nil }
        default:
            let hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: Self.modifiers(event.modifierFlags))
            if let issue = model.settings.problem(with: hotkey, for: slot) {
                problem = issue
                NSSound.beep()
                return
            }
            stop()
            model.update { $0[slot] = hotkey }
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Set<Hotkey.Modifier> {
        var result: Set<Hotkey.Modifier> = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}
