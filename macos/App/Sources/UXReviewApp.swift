import AppKit
import SwiftUI
import UXReviewKit

/// Menu-bar-only app (`LSUIElement`): capture from the menu or a global hotkey, annotate drafts
/// in the editor window, and submit them to Hot Sheet from the review session window (docs/07).
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
        // Headless modes used by scripts/app-e2e.sh: run once, print a JSON result, and exit.
        // Synchronous: --settings (apply/print settings, check the hotkey), --annotate (run an
        // editing script on a draft), --submit (file a draft in Hot Sheet, docs/07 §7.8).
        let arguments = Array(CommandLine.arguments.dropFirst())
        let synchronous: [(String, @MainActor @Sendable ([String]) -> Int32)] = [
            ("--settings", HeadlessSettings.run(arguments:)),
            ("--annotate", HeadlessAnnotate.run(arguments:)),
            ("--submit", HeadlessSubmit.run(arguments:)),
        ]
        for (flag, run) in synchronous where CommandLine.arguments.contains(flag) {
            startHeadless()
            exit(MainActor.assumeIsolated { run(arguments) })
        }
        // Asynchronous: --import (add existing files to the draft), --open-media (route files like
        // Finder "Open With" or an editor drop), --capture (one capture).
        let asynchronous: [(String, @MainActor @Sendable ([String]) async -> Int32)] = [
            ("--import", HeadlessImport.run(arguments:)),
            ("--open-media", HeadlessOpenMedia.run(arguments:)),
            ("--capture", HeadlessCapture.run(arguments:)),
        ]
        for (flag, run) in asynchronous where CommandLine.arguments.contains(flag) {
            startHeadless()
            Task { @MainActor in await exit(run(arguments)) }
            dispatchMain()
        }
        UXReviewApp.main()
    }

    /// An app object without a Dock icon or menu bar item, for the headless modes.
    private static func startHeadless() {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
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
        capture.narrationDefault = { [weak settings] in settings?.settings.narration ?? false }
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
