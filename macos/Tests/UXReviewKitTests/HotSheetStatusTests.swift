import Foundation
import Testing
@testable import UXReviewKit

struct HotSheetStatusTests {
    @Test func missingCLIIsReportedFirst() {
        let status = HotSheetStatus.detect(projectDirectory: nil, environment: [:], isExecutable: { _ in false })
        #expect(!status.isReady)
        #expect(status.cliPath == nil)
        #expect(status.summary == "Hot Sheet: hotsheet-cli not found. Install Hot Sheet 2 or set HOTSHEET_CLI.")
    }

    @Test func missingProjectIsReported() {
        let status = HotSheetStatus.detect(projectDirectory: nil, environment: ["HOTSHEET_CLI": "/x/hs"], isExecutable: { _ in true })
        #expect(status.cliPath == "/x/hs")
        #expect(status.problem == "No project selected.")
    }

    @Test func missingStoreAndReadyStates() throws {
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["HOTSHEET_CLI": "/x/hs"]
        let project = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let missing = HotSheetStatus.detect(projectDirectory: project, environment: env, isExecutable: { _ in true })
        #expect(missing.problem == "No Hot Sheet store found for \(project.path).")

        let store = root.appendingPathComponent("proj.hs2")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: store.appendingPathComponent("hotsheet-store.json"))
        let ready = HotSheetStatus.detect(projectDirectory: project, environment: env, isExecutable: { _ in true })
        #expect(ready.isReady)
        #expect(ready.storePath == store.path)
        #expect(ready.summary == "Hot Sheet: ready (proj.hs2)")
    }
}
