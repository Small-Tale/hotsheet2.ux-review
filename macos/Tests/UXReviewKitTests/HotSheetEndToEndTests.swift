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
        // HS2-EZN3NG: the narrated clip is flagged in the ticket text and in the attached bundle.
        #expect(ticket.contains("(video, 2880×1800, 0:08.000, with audio)"))
        #expect(ticket.contains("have a sound track, usually the reviewer's spoken narration"))

        // The attached review.json is byte-identical to what the submitter wrote.
        let attachments = store.appendingPathComponent("attachments")
        let enumerator = FileManager.default.enumerator(at: attachments, includingPropertiesForKeys: nil)
        let stored = (enumerator?.allObjects as? [URL] ?? []).first { $0.lastPathComponent == "review.json" }
        let storedBundle = try #require(stored)
        #expect(try Data(contentsOf: storedBundle) == Data(contentsOf: media.appendingPathComponent("review.json")))
        let attached = try ReviewBundle.makeDecoder().decode(ReviewBundle.self, from: Data(contentsOf: storedBundle))
        #expect(attached.media.map(\.hasAudio) == [nil, true])
    }

    /// The review session path (docs/07 §7.5): a draft with three captures, filed by
    /// `DraftSubmitter` into a real store; the draft is deleted and the ticket file reported.
    @Test(.enabled(if: cli != nil, "hotsheet-cli not installed"), .timeLimit(.minutes(2)))
    func submitsAMultiCaptureDraftAndCleansUp() throws {
        let cli = try #require(Self.cli)
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("project.hs2")
        var env = ProcessInfo.processInfo.environment
        env["HOTSHEET_ACTOR_ROLE"] = nil
        env["HOTSHEET_ACTOR_ID"] = nil
        let runner = SystemProcessRunner()
        let initResult = try runner.run(executable: cli, arguments: ["-C", store.path, "init"], environment: env, currentDirectory: nil)
        try #require(initResult.exitCode == 0, "init failed: \(initResult.stderr)")

        let drafts = ReviewDraftStore(root: root.appendingPathComponent("Drafts"))
        var directory: URL?
        for (index, kind) in [MediaKind.image, .video, .image].enumerated() {
            let file = root.appendingPathComponent("raw-\(index).\(kind == .image ? "png" : "mov")")
            try Data("capture \(index)".utf8).write(to: file)
            directory = try drafts.add(DraftCapture(
                fileURL: file, kind: kind, pixelWidth: 640, pixelHeight: 400, durationMs: kind == .video ? 2000 : nil,
                capturedAt: Date(), context: CaptureContext(appName: "Safari", windowTitle: "Checkout"), hasAudio: kind == .video
            )).draft.directory
        }
        let draft = try #require(directory)
        try drafts.update(draft) { bundle in
            bundle.annotations = [
                Annotation(
                    id: "a1",
                    mediaId: "m1",
                    shape: .rect(NormRect(x: 100, y: 100, width: 2000, height: 900)),
                    intents: [.bug],
                    note: "Clipped"
                ),
                Annotation(
                    id: "a2", mediaId: "m2", shape: .insertion(NormPoint(x: 5000, y: 5000)), note: "Add a hint",
                    timeRange: TimeRange(startMs: 500, endMs: 1500)
                ),
            ]
        }

        let client = HotSheetCLIClient(executable: cli, storePath: store, runner: runner)
        let result = try DraftSubmitter(store: drafts, client: client, storePath: store)
            .submit(draft, title: "Checkout flow", summary: "Three captures from the checkout.")
        #expect(result.mediaCount == 3 && result.annotationCount == 2 && result.draftRemoved)
        let ticketFile = try #require(result.ticket.file)
        #expect(FileManager.default.fileExists(atPath: ticketFile))
        #expect(!FileManager.default.fileExists(atPath: draft.path))
        #expect(try drafts.current() == nil)

        let show = try runner.run(
            executable: cli,
            arguments: ["-C", store.path, "show", result.ticket.slug],
            environment: env,
            currentDirectory: nil
        )
        try #require(show.exitCode == 0, "show failed: \(show.stderr)")
        for name in ["capture-1.png", "capture-2.mov", "capture-3.png", "review.json"] {
            #expect(show.stdout.contains("filename: \(name)"))
        }
        #expect(show.stdout.contains("UX review: Checkout flow"))
        #expect(show.stdout.contains("Three captures from the checkout."))
        #expect(show.stdout.contains("### #2 · insert · `attachment:capture-2.mov`"))
        #expect(show.stdout.contains("`attachment:capture-2.mov` (video, 640×400, 0:02.000, with audio)"))
        #expect(!show.stdout.contains("submission.json"))
        #expect(!show.stdout.contains("filename: originals"))
    }
}
