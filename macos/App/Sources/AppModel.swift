import AppKit
import Combine
import SwiftUI
import UXReviewKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: HotSheetStatus
    private var projectChanges: AnyCancellable?

    init() {
        status = AppSettings.currentStatus()
        projectChanges = NotificationCenter.default.publisher(for: .hotSheetProjectChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func refresh() {
        status = AppSettings.currentStatus()
    }

    func chooseProject() {
        if let url = AppSettings.chooseProjectFolder() {
            AppSettings.useProject(url)
        }
    }
}
