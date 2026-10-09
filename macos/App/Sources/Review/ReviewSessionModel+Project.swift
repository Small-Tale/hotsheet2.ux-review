import AppKit
import UXReviewKit

/// Choosing the Hot Sheet project in the Submit Review window (docs/07 §7.6).
extension ReviewSessionModel {
    func useProject(_ url: URL) {
        guard session.isEditable else { return }
        // Choosing a project replaces the one a capture link named for this review.
        var launch = DraftLaunch.load(from: directory)
        if launch.projectDirectory != nil {
            launch.projectDirectory = nil
            try? launch.save(to: directory)
        }
        AppSettings.useProject(url)
        refreshTarget()
    }

    func chooseProject() {
        if let url = AppSettings.chooseProjectFolder() { useProject(url) }
    }

    /// Reads Hot Sheet's registered projects (`hotsheet-cli checkout list`) off the main thread,
    /// for the Change menu (`HS2-T32CZC`). Once per window; without the CLI there are none.
    func loadHotSheetProjects() {
        guard hotSheetProjects.isEmpty, let cli = session.target.cliPath ?? statusProvider().cliPath else { return }
        Task { [weak self] in
            let projects = await Task.detached { HotSheetProjects.list(cliPath: cli) }.value
            self?.hotSheetProjects = projects
        }
    }
}
