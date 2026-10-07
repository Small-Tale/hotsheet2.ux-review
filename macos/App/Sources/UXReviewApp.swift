import AppKit
import SwiftUI
import UXReviewKit

/// Menu-bar-only app (`LSUIElement`). Capture, annotation, and submission UI arrive in
/// follow-up tickets; see docs/README.md for the roadmap.
@main
enum UXReviewMain {
    static func main() {
        // Headless smoke mode used by scripts/check.sh: print Hot Sheet status as JSON and exit.
        if CommandLine.arguments.contains("--status") {
            let status = AppSettings.currentStatus()
            let data = (try? JSONEncoder().encode(status)) ?? Data("{}".utf8)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(status.isReady ? 0 : 3)
        }
        // Offscreen renders of the capture UI for visual QA (no Screen Recording permission needed).
        if let index = CommandLine.arguments.firstIndex(of: "--render-ui-previews"), index + 1 < CommandLine.arguments.count {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            let code: Int32 = MainActor.assumeIsolated {
                do {
                    try UIPreviews.render(to: directory).forEach { print($0.path) }
                    return 0
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                    return 1
                }
            }
            exit(code)
        }
        // Headless settings used by scripts/app-e2e.sh: apply/print settings, check the hotkey.
        if CommandLine.arguments.contains("--settings") {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
            exit(MainActor.assumeIsolated { HeadlessSettings.run(arguments: Array(CommandLine.arguments.dropFirst())) })
        }
        // Headless capture used by scripts/app-e2e.sh: one capture, JSON result, exit.
        if CommandLine.arguments.contains("--capture") {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { @MainActor in
                await exit(HeadlessCapture.run(arguments: Array(CommandLine.arguments.dropFirst())))
            }
            dispatchMain()
        }
        UXReviewApp.main()
    }
}

struct UXReviewApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var capture: CaptureCoordinator
    @StateObject private var settings: SettingsModel

    init() {
        let capture = CaptureCoordinator()
        let settings = SettingsModel()
        // The global hotkey starts the default capture, or cancels a running countdown.
        settings.hotkeys.onPress = { [weak capture, weak settings] in
            guard let capture, let settings else { return }
            capture.handleHotkey(settings: settings.settings)
        }
        capture.stopHint = { [weak settings] in
            settings?.settings.captureHotkey.map { "Stop from the menu bar or press \($0.display)" } ?? "Stop from the menu bar"
        }
        _capture = StateObject(wrappedValue: capture)
        _settings = StateObject(wrappedValue: settings)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, capture: capture, settings: settings)
        } label: {
            // A record symbol while recording, so the reviewer always sees that it is running.
            Image(systemName: capture.phase.isRecording ? "record.circle.fill" : "viewfinder")
                .accessibilityLabel(capture.phase.isRecording ? "UX Review — recording" : "UX Review")
        }
        Settings {
            SettingsView(model: settings)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: CaptureCoordinator
    @ObservedObject var settings: SettingsModel

    var body: some View {
        CaptureMenuSection(capture: capture, settings: settings)
        Divider()
        Text(model.status.summary)
        if let project = model.status.projectDirectory {
            Text("Project: \((project as NSString).lastPathComponent)")
        }
        Divider()
        Button("Choose Project Folder…") { model.chooseProject() }
        Button("Refresh Hot Sheet Status") { model.refresh() }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Text("UX Review \(AppSettings.version)")
        Button("Quit UX Review") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
