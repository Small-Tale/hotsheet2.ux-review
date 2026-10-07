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
    @StateObject private var capture = CaptureCoordinator()

    var body: some Scene {
        MenuBarExtra("UX Review", systemImage: "viewfinder") {
            MenuContent(model: model, capture: capture)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: CaptureCoordinator

    var body: some View {
        CaptureMenuSection(capture: capture)
        Divider()
        Text(model.status.summary)
        if let project = model.status.projectDirectory {
            Text("Project: \((project as NSString).lastPathComponent)")
        }
        Divider()
        Button("Choose Project Folder…") { model.chooseProject() }
        Button("Refresh Hot Sheet Status") { model.refresh() }
        Divider()
        Text("UX Review \(AppSettings.version)")
        Button("Quit UX Review") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
