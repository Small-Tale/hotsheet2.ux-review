import SwiftUI
import UXReviewKit

/// Submit Review's **Change** menu (docs/07 §7.6): recent projects first, the current one checked
/// (`HS2-D1T46P`); then, under "Hot Sheet Projects", the projects Hot Sheet knows that aren't
/// recent (`HS2-T32CZC`, read when the window opens); **Choose Folder…** last.
struct ProjectChangeMenu: View {
    @ObservedObject var model: ReviewSessionModel

    var body: some View {
        Menu("Change") {
            let projects = model.projectMenu
            ForEach(Array(projects.enumerated()), id: \.element.path) { index, project in
                if project.isFromHotSheet, index == 0 || !projects[index - 1].isFromHotSheet {
                    if index > 0 { Divider() }
                    Text("Hot Sheet Projects")
                }
                Toggle(isOn: Binding(
                    get: { project.isCurrent },
                    set: { _ in if !project.isCurrent { model.useProject(URL(fileURLWithPath: project.path, isDirectory: true)) } }
                )) {
                    Text(project.title)
                }
                .help((project.path as NSString).abbreviatingWithTildeInPath)
            }
            if !projects.isEmpty { Divider() }
            Button("Choose Folder…") { model.chooseProject() }
        }
        .fixedSize()
        .task { model.loadHotSheetProjects() }
    }
}
