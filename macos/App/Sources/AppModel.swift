import AppKit
import SwiftUI
import UXReviewKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: HotSheetStatus

    init() {
        status = AppSettings.currentStatus()
    }

    func refresh() {
        status = AppSettings.currentStatus()
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the project whose Hot Sheet store should receive UX reviews."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.projectDirectory = url
            refresh()
        }
    }
}
