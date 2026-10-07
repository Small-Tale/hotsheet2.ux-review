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
        UXReviewApp.main()
    }
}

struct UXReviewApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("UX Review", systemImage: "viewfinder") {
            MenuContent(model: model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
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
