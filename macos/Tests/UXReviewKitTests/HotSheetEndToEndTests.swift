import Foundation
import Testing
@testable import UXReviewKit

/// End-to-end: submits a real review through the real `hotsheet-cli` into a throwaway store and
/// reads the resulting ticket file back. Skipped when `hotsheet-cli` is not installed; set
/// `UXREVIEW_REQUIRE_HOTSHEET=1` (as `scripts/check.sh` does) to make a missing CLI a failure.
struct HotSheetEndToEndTests {
    static let cli = HotSheetLocator.findCLI()
    static let required = ProcessInfo.processInfo.environment["UXREVIEW_REQUIRE_HOTSHEET"] == "1"
    /// Whether this `hotsheet-cli` has `annotate` (Hot Sheet 2 `HS2-3GA0WK`); older ones file
    /// reviews without gallery regions.
    static let supportsAnnotate: Bool = {
        guard let cli else { return false }
        let result = try? SystemProcessRunner().run(
            executable: cli, arguments: ["annotate", "--help"], environment: [:], currentDirectory: nil
        )
        return result?.exitCode == 0
    }()

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
            ticket.contains("title: Settings window polish") || ticket.contains("title: 'Settings window polish'")
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
        // HS2-HQV9R8: a span's heads reach the ticket, and it defaults to comment.
        #expect(ticket.contains("### #6 · comment · `attachment:capture-1.png`"))
        #expect(ticket.contains("- Shape: arrow (start flat, end flat);"))
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

        // HS2-K1XT5V: each capture's regions reach Hot Sheet's gallery when the CLI can write them.
        try Self.expectGalleryRegions(slug, bundle: bundle, client: client, env: env)
    }

    /// With a CLI that has `annotate`, each annotated capture holds exactly its projection; with an
    /// older one, the ticket has no annotations.
    static func expectGalleryRegions(_ slug: String, bundle: ReviewBundle, client: HotSheetCLIClient, env: [String: String]) throws {
        let ids = try client.attachmentIDs(on: slug)
        let projection = TicketComposer.compose(bundle).hotSheetAnnotations
        let ticketFile = try URL(fileURLWithPath: #require(client.findTicket(slug)?.file))
        let before = try Data(contentsOf: ticketFile)
        for (filename, mediaID) in [("capture-1.png", "m1"), ("capture-2.mov", "m2")] {
            let stored = try storedAnnotations(
                resending: projection[mediaID] ?? [], to: slug, attachment: #require(ids[filename]), client: client, env: env
            )
            if supportsAnnotate {
                #expect(stored == projection[mediaID], "\(filename)")
            }
        }
        if supportsAnnotate {
            #expect(projection["m1"]?.first?.text.hasPrefix("#1 [") == true)
            // Re-sending identical annotations is a no-op, so the ticket already held exactly these.
            #expect(try Data(contentsOf: ticketFile) == before)
        } else {
            #expect(String(bytes: before, encoding: .utf8)?.contains("annotations:") == false)
        }
    }

    /// Sends `annotations` to one attachment with `annotate --json` and returns what Hot Sheet
    /// stored (nil from a CLI without `annotate`). An identical batch changes nothing.
    static func storedAnnotations(
        resending annotations: [HotSheetMediaAnnotation], to slug: String, attachment: String, client: HotSheetCLIClient,
        env: [String: String]
    ) throws -> [HotSheetMediaAnnotation]? {
        struct Attachment: Decodable { var annotations: [HotSheetMediaAnnotation]? }
        let file = try TestSupport.makeTempDirectory().appendingPathComponent("annotations.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try JSONEncoder().encode(annotations).write(to: file)
        let result = try SystemProcessRunner().run(
            executable: client.executable,
            arguments: [
                "-C", client.storePath.path, "annotate", "--actor-role=human", "--actor-id=ux-review",
                slug, attachment, "--file=\(file.path)", "--json",
            ],
            environment: env,
            currentDirectory: nil
        )
        guard result.exitCode == 0 else { return nil }
        return try JSONDecoder().decode(Attachment.self, from: Data(result.stdout.utf8)).annotations ?? []
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
        #expect(show.stdout.contains("title: Checkout flow"))
        #expect(show.stdout.contains("Three captures from the checkout."))
        #expect(show.stdout.contains("### #2 · insert · `attachment:capture-2.mov`"))
        #expect(show.stdout.contains("`attachment:capture-2.mov` (video, 640×400, 0:02.000, with audio)"))
        #expect(!show.stdout.contains("submission.json"))
        #expect(!show.stdout.contains("filename: originals"))
    }

    /// HS2-E3001H (docs/03 §3.5, docs/07 §7.5): a draft added to a ticket that already exists and
    /// already has a `review.json` and a `capture-1.png`. The lookup reads its title, the note
    /// cites the names Hot Sheet stored the colliding files under, and a failed note resumes
    /// without a second batch.
    @Test(.enabled(if: cli != nil, "hotsheet-cli not installed"), .timeLimit(.minutes(2)))
    func addsADraftToAnExistingTicket() throws {
        let cli = try #require(Self.cli)
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("project.hs2")
        var env = ProcessInfo.processInfo.environment
        env["HOTSHEET_ACTOR_ROLE"] = nil
        env["HOTSHEET_ACTOR_ID"] = nil
        let runner = SystemProcessRunner()
        func hs(_ args: String...) throws -> ProcessResult {
            try runner.run(executable: cli, arguments: ["-C", store.path] + args, environment: env, currentDirectory: nil)
        }
        try #require(try hs("init").exitCode == 0)
        let client = HotSheetCLIClient(executable: cli, storePath: store, runner: runner)
        let existing = try Self.ticketWithEarlierFiles(client, scratch: root)

        // The lookup, as the window and --to-ticket run it.
        let query = TicketQuery(reference: try #require(TicketReference.parse(existing.slug.lowercased())), storePath: store.path)
        let found = try #require(try query.run(cliPath: cli.path).get())
        #expect(found.title == "Accounts page: it's “redesign” time")
        #expect(found.status == "not_started" && found.file == existing.file)
        #expect(try TicketQuery(reference: "HS-NOPE00", storePath: store.path).run(cliPath: cli.path).get() == nil)

        let drafts = ReviewDraftStore(root: root.appendingPathComponent("Drafts"))
        let draft = try Self.imageAndVideoDraft(in: drafts, raw: root)
        try drafts.update(draft) { bundle in
            bundle.annotations = [Annotation(
                id: "a1", mediaId: "m1", shape: .rect(NormRect(x: 100, y: 100, width: 2000, height: 900)), intents: [.bug],
                note: "Still clipped"
            )]
        }

        // The note fails once (a CLI wrapper that refuses the first `edit`); the retry adds only the note.
        let failOnce = FailingFirstEdit(runner: runner)
        let flaky = HotSheetCLIClient(executable: cli, storePath: store, runner: failOnce)
        #expect(throws: SubmissionFailure.self) {
            try DraftSubmitter(store: drafts, client: flaky, storePath: store).submit(draft, title: "Follow-up", into: found)
        }
        #expect(drafts.pendingSubmission(in: draft)?.attachedNames?["capture-1.png"] == "capture-1 (2).png")
        let result = try DraftSubmitter(store: drafts, client: flaky, storePath: store).submit(draft, title: "Follow-up", into: found)
        #expect(result.addedToExistingTicket && result.ticket.slug == existing.slug && result.ticketTitle == found.title)
        #expect(!FileManager.default.fileExists(atPath: draft.path))

        let show = try hs("show", existing.slug)
        try #require(show.exitCode == 0, "show failed: \(show.stderr)")
        let ticket = show.stdout
        #expect(ticket.contains("Original body."))
        #expect(ticket.components(separatedBy: "## UX review: Follow-up").count == 2, "exactly one review note")
        for name in ["capture-1 (2).png", "capture-2.mov", "review (2).json"] {
            #expect(ticket.contains("filename: \(name)"), "attached \(name)")
        }
        #expect(ticket.components(separatedBy: "batch_label: UX review capture").count == 4, "one batch of three files")
        #expect(ticket.contains("#### #1 · bug · `attachment:capture-1 (2).png`"))
        #expect(ticket.contains("`attachment:review (2).json` is the canonical"))
        #expect(ticket.contains("calls it `capture-1.png`"))
        #expect(ticket.contains("actor: human"))
        #expect(!ticket.contains("Instructions for the AI"))
        // Only the original ticket exists.
        #expect(try hs("ls").stdout.split(separator: "\n").count(where: { $0.contains("HS-") }) == 1)
    }

    /// HS2-1DDKZ3: a draft's edited preambles reach the real ticket: the intake body of a new
    /// ticket, then the note on an existing one, with placeholders filled in (the record by the
    /// name Hot Sheet stored it under).
    @Test(.enabled(if: cli != nil, "hotsheet-cli not installed"), .timeLimit(.minutes(2)))
    func filesTheDraftsEditedTicketText() throws {
        let cli = try #require(Self.cli)
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("project.hs2")
        var env = ProcessInfo.processInfo.environment
        env["HOTSHEET_ACTOR_ROLE"] = nil
        env["HOTSHEET_ACTOR_ID"] = nil
        let runner = SystemProcessRunner()
        func hs(_ args: String...) throws -> ProcessResult {
            try runner.run(executable: cli, arguments: ["-C", store.path] + args, environment: env, currentDirectory: nil)
        }
        try #require(try hs("init").exitCode == 0)
        let client = HotSheetCLIClient(executable: cli, storePath: store, runner: runner)
        let drafts = ReviewDraftStore(root: root.appendingPathComponent("Drafts"))

        let first = try Self.imageAndVideoDraft(in: drafts, raw: root)
        try drafts.setTicketText("## Split {{title}}\n\nOne ticket per change; see {{record}} and {{media}}.", for: .newTicket, in: first)
        let filed = try DraftSubmitter(store: drafts, client: client, storePath: store).submit(first, title: "Checkout")
        let intake = try hs("show", filed.ticket.slug).stdout
        #expect(intake.contains(
            "## Split Checkout\n\nOne ticket per change; see `attachment:review.json` and "
                + "`attachment:capture-1.png`, `attachment:capture-2.mov`.\n\n## Capture context"
        ))
        #expect(!intake.contains("Instructions for the AI"))

        let existing = try Self.ticketWithEarlierFiles(client, scratch: root)
        let found = try #require(try TicketQuery(reference: existing.slug, storePath: store.path).run(cliPath: cli.path).get())
        let second = try Self.imageAndVideoDraft(in: drafts, raw: root)
        try drafts.setTicketText("## More on {{title}}\n\n{{counts}}; record {{record}}.", for: .existingTicket, in: second)
        _ = try DraftSubmitter(store: drafts, client: client, storePath: store).submit(second, title: "Follow-up", into: found)
        let ticket = try hs("show", existing.slug).stdout
        #expect(ticket.contains("## More on Follow-up\n\n2 captures and 0 annotations; record `attachment:review (2).json`."))
        #expect(!ticket.contains("Feedback on this ticket, added with UX Review"))
    }
}

extension HotSheetEndToEndTests {
    /// A ticket that already holds a `capture-1.png` and a `review.json`, as one filed from an
    /// earlier review would.
    static func ticketWithEarlierFiles(_ client: HotSheetCLIClient, scratch: URL) throws -> CreatedTicket {
        let ticket = try client.createTicketReportingFile(NewTicket(
            title: "Accounts page: it's “redesign” time",
            details: "Original body."
        ))
        let earlier = scratch.appendingPathComponent("earlier")
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        let files = ["capture-1.png", "review.json"].map { earlier.appendingPathComponent($0) }
        for file in files {
            try Data("earlier \(file.lastPathComponent)".utf8).write(to: file)
        }
        try client.attach(files: files, to: ticket.slug, batchLabel: nil, purpose: nil)
        return ticket
    }

    /// A draft with `capture-1.png` and `capture-2.mov` (fake bytes), as captures would leave it.
    static func imageAndVideoDraft(in drafts: ReviewDraftStore, raw: URL) throws -> URL {
        var directory: URL?
        for (index, kind) in [MediaKind.image, .video].enumerated() {
            let file = raw.appendingPathComponent("raw-\(index).\(kind == .image ? "png" : "mov")")
            try Data("capture \(index)".utf8).write(to: file)
            directory = try drafts.add(DraftCapture(
                fileURL: file, kind: kind, pixelWidth: 640, pixelHeight: 400, durationMs: kind == .video ? 2000 : nil, capturedAt: Date(),
                context: CaptureContext(appName: "Safari")
            )).draft.directory
        }
        return try #require(directory)
    }
}

/// Runs the real CLI, but fails the first `edit` like a locked store would.
private final class FailingFirstEdit: ProcessRunning, @unchecked Sendable {
    let runner: ProcessRunning
    private var failed = false

    init(runner: ProcessRunning) {
        self.runner = runner
    }

    func run(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) throws -> ProcessResult {
        if arguments.contains("edit"), !failed {
            failed = true
            return ProcessResult(exitCode: 1, stdout: "", stderr: "Error: the store is locked")
        }
        return try runner.run(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory)
    }
}
