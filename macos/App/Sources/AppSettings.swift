import AppKit
import Foundation
import UXReviewKit

extension Notification.Name {
    /// Posted after the target project changes, so the menu and open session windows refresh.
    static let hotSheetProjectChanged = Notification.Name("UXReviewHotSheetProjectChanged")
    /// Posted after Settings change (for example Downscale for AI), so open session windows refresh.
    static let captureSettingsChanged = Notification.Name("UXReviewCaptureSettingsChanged")
}

/// User-level settings. The project folder can also be given with `--project <path>`.
enum AppSettings {
    /// Whether filed captures are scaled down for AI (Settings › Submitting, docs/07 §7.5.1).
    static var downscaleForAI: Bool { CaptureSettingsStore.load(from: defaults).downscaleForAI }

    /// The AI size for the project's store: its default AI tool's (`hotsheet-cli ai-settings`),
    /// else 2048 px. Blocking; call it off the main thread.
    static func scaleTarget(cliPath: String, storePath: String) -> MediaScaleTarget {
        MediaScaleTarget.detect(using: HotSheetCLIClient(
            executable: URL(fileURLWithPath: cliPath),
            storePath: URL(fileURLWithPath: storePath)
        ))
    }

    private static let projectKey = "projectDirectory"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var projectDirectory: URL? {
        get {
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--project"), index + 1 < args.count {
                return URL(fileURLWithPath: args[index + 1], isDirectory: true)
            }
            return defaults.string(forKey: projectKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set { defaults.set(newValue?.path, forKey: projectKey) }
    }

    static func currentStatus() -> HotSheetStatus {
        HotSheetStatus.detect(projectDirectory: projectDirectory)
    }

    /// Project folders used before, most recent first, that still exist (docs/07 §7.6).
    static var recentProjects: [String] {
        RecentProjectsStore.load(from: defaults).existing()
    }

    /// Makes `url` the target project, remembers it among the recent ones, and tells open
    /// windows. Spec: docs/07-review-session.md §7.6.
    static func useProject(_ url: URL) {
        projectDirectory = url
        rememberProject(url.path)
        NotificationCenter.default.post(name: .hotSheetProjectChanged, object: nil)
    }

    static func rememberProject(_ path: String) {
        var recent = RecentProjectsStore.load(from: defaults)
        recent.use(path)
        try? RecentProjectsStore.save(recent, to: defaults)
    }

    /// The open panel for choosing a project folder; nil when cancelled.
    @MainActor static func chooseProjectFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project whose Hot Sheet store should receive UX reviews."
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
