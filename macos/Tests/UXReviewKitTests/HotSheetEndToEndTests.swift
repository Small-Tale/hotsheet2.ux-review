import Foundation
import Testing
@testable import UXReviewKit

/// End-to-end: submits a real review through the real `hotsheet-cli` into a throwaway store and
/// reads the resulting ticket file back. Skipped when `hotsheet-cli` is not installed; set
/// `UXREVIEW_REQUIRE_HOTSHEET=1` (as `scripts/check.sh` does) to make a missing CLI a failure.
struct HotSheetEndToEndTests {
    static let cli = HotSheetLocator.findCLI()
    static let required = ProcessInfo.processInfo.environment["UXREVIEW_REQUIRE_HOTSHEET"] == "1"

    @Test func hotSheetCLIIsAvailableWhenRequired() {
        if Self.required { #expect(Self.cli != nil, "hotsheet-cli not found; set HOTSHEET_CLI or add it to PATH") }
    }

    @Test(.enabled(if: cli != nil, "hotsheet-cli not installed"))
    func submitsExampleReviewIntoRealStore() throws {
        let cli = try #require(Self.cli)
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store.hs2")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)

        var env = ProcessInfo.processInfo.environment
        env["HOTSHEET_ACTOR_ROLE"] = nil
        env["HOTSHEET_ACTOR_ID"] = nil
        let runner = SystemProcessRunner()
        let initResult = try runner.run(executable: cli, arguments: ["-C", store.path, "init"], environment: env, currentDirectory: nil)
        try #require(initResult.exitCode == 0, "init failed: \(initResult.stderr)")
        #expect(try HotSheetLocator.resolveStore(for: store, environment: [:]).path == store.path)

        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let bundle = try TestSupport.exampleBundle()
        for item in bundle.media {
            try Data("fake \(item.kind.rawValue) bytes".utf8).write(to: media.appendingPathComponent(item.filename))
        }

        // The AI-session identity in this process's environment must not leak into the write.
        let client = HotSheetCLIClient(
            executable: cli,
            storePath: store,
            runner: runner,
            baseEnvironment: ProcessInfo.processInfo.environment
        )
        let slug = try ReviewSubmitter(client: client).submit(bundle, mediaDirectory: media)
        #expect(slug.hasPrefix("HS-"))

        let show = try runner.run(executable: cli, arguments: ["-C", store.path, "show", slug], environment: env, currentDirectory: nil)
        try #require(show.exitCode == 0, "show failed: \(show.stderr)")
        let ticket = show.stdout
        #expect(
            ticket.contains("title: 'UX review: Settings window polish'") || ticket
                .contains("title: \"UX review: Settings window polish\"")
                || ticket.contains("title: UX review: Settings window polish")
        )
        #expect(ticket.contains("category: task"))
        #expect(ticket.contains("- ux-review"))
        for name in ["capture-1.png", "capture-2.mov", "review.json"] {
            #expect(ticket.contains("filename: \(name)"))
        }
        #expect(ticket.contains("batch_label: UX review capture"))
        #expect(ticket.contains("purpose: problem_evidence"))
        #expect(ticket.contains("role: human"))
        #expect(!ticket.contains("role: ai"))
        #expect(ticket.contains("## Instructions for the AI processing this ticket"))
        #expect(ticket.contains("### #5 · bug · `attachment:capture-2.mov`"))

        // The attached review.json is byte-identical to what the submitter wrote.
        let attachments = store.appendingPathComponent("attachments")
        let enumerator = FileManager.default.enumerator(at: attachments, includingPropertiesForKeys: nil)
        let stored = (enumerator?.allObjects as? [URL] ?? []).first { $0.lastPathComponent == "review.json" }
        let storedBundle = try #require(stored)
        #expect(try Data(contentsOf: storedBundle) == Data(contentsOf: media.appendingPathComponent("review.json")))
    }
}
