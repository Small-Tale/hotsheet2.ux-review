import AppKit
import SwiftUI
import UXReviewKit

/// Menu-bar-only app (`LSUIElement`): capture from the menu or a global hotkey, annotate drafts
/// in the editor window. Submission UI arrives in a follow-up ticket; see docs/README.md.
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
        // Headless annotation used by scripts/app-e2e.sh: run an editing script on a draft, JSON result, exit.
        if CommandLine.arguments.contains("--annotate") {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
            exit(MainActor.assumeIsolated { HeadlessAnnotate.run(arguments: Array(CommandLine.arguments.dropFirst())) })
        }
        // Headless import used by scripts/app-e2e.sh: add existing files to the draft, JSON result, exit.
        if CommandLine.arguments.contains("--import") {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { @MainActor in
                await exit(HeadlessImport.run(arguments: Array(CommandLine.arguments.dropFirst())))
            }
            dispatchMain()
        }
        // Headless open used by scripts/app-e2e.sh: route files like Finder "Open With" or an editor drop.
        if CommandLine.arguments.contains("--open-media") {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { @MainActor in
                await exit(HeadlessOpenMedia.run(arguments: Array(CommandLine.arguments.dropFirst())))
            }
            dispatchMain()
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
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var capture: CaptureCoordinator
    @StateObject private var settings: SettingsModel

    init() {
        let capture = CaptureCoordinator()
        let settings = SettingsModel()
        // A global hotkey starts its capture, or cancels a countdown / stops a recording.
        settings.hotkeys.onPress = { [weak capture, weak settings] slot in
            guard let capture, let settings else { return }
            capture.handleHotkey(slot, settings: settings.settings)
        }
        capture.stopHint = { [weak settings] in
            let hotkey = settings?.activeHotkey(.record) ?? settings?.activeHotkey(.capture)
            return hotkey.map { "Stop from the menu bar or press \($0.display)" } ?? "Stop from the menu bar"
        }
        // Images and movies opened from Finder go into the current draft (docs/04 §4.12.1).
        AppDelegate.openHandler = { [weak capture] urls in capture?.openMedia(urls) }
        _capture = StateObject(wrappedValue: capture)
        _settings = StateObject(wrappedValue: settings)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, capture: capture, settings: settings)
        } label: {
            StatusBarIcon(isRecording: capture.phase.isRecording)
        }
        Settings {
            SettingsView(model: settings)
        }
    }
}

/// The menu bar icon: UX Review's flame-in-viewfinder template image (Assets.xcassets), or a
/// record symbol while recording so the reviewer always sees that it is running. Spec: docs/05 §5.1.
struct StatusBarIcon: View {
    static let assetName = "StatusBarIcon"
    let isRecording: Bool

    var body: some View {
        Group {
            if isRecording {
                Image(systemName: "record.circle.fill")
            } else {
                Image(Self.assetName)
            }
        }
        .accessibilityLabel(isRecording ? "UX Review — recording" : "UX Review")
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
