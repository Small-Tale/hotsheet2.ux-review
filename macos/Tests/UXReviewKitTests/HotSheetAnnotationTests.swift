import Foundation
import Testing
@testable import UXReviewKit

/// Writing the Hot Sheet annotation projection after a review's media is attached (docs/03 §3.4,
/// `HS2-K1XT5V`): the CLI transport's `show`/`annotate`, and the submitter's best-effort pass.
struct HotSheetAnnotationTests {
    // MARK: Reading attachment ids from `hotsheet-cli show`

    /// The front matter shape `hotsheet-cli show` prints, with an annotated attachment, a quoted
    /// renamed file, and keys after the list.
    static let showOutput = """
    ---
    id: 01M4FS6YFMYB1HH8KGZV1H22CA
    slug: HS-R5J6XP
    title: t
    attachments:
    - id: 01M4FS6YFMYB1HH8KGZV1H22CJ
      filename: capture-1.png
      created_at: 2026-10-09T07:32:01.140014Z
      batch_id: batch-1
      actor:
        role: human
      annotations:
      - id: a1
        x: 100
        y: 200
        width: 300
        height: 400
        text: '#1 [bug] hi'
    - filename: 'capture-1 (2).png'
      id: 01M4FS6YFMYB1HH8KGZV1H22CK
    - id: "01M4FS6YFMYB1HH8KGZV1H22CM"
      filename: review.json
    schema: hotsheet/v2-bounded-notes
    filename: not-an-attachment.png
    ---

    <!-- hotsheet:body:begin -->
    filename: body text
    """

    @Test func parsesAttachmentIdsByStoredNameIgnoringNestedLists() {
        #expect(HotSheetTicket.parseAttachments(Self.showOutput) == [
            "capture-1.png": "01M4FS6YFMYB1HH8KGZV1H22CJ",
            "capture-1 (2).png": "01M4FS6YFMYB1HH8KGZV1H22CK",
            "review.json": "01M4FS6YFMYB1HH8KGZV1H22CM",
        ])
        #expect(HotSheetTicket.parseAttachments("---\nid: X\nslug: HS-1\n---\n").isEmpty)
        #expect(HotSheetTicket.parseAttachments("").isEmpty)
    }

    // MARK: CLI transport

    private let cli = URL(fileURLWithPath: "/bin/hotsheet-cli")
    private let store = URL(fileURLWithPath: "/stores/demo.hs2")

    @Test func attachmentIdsComeFromShow() throws {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: Self.showOutput, stderr: "")])
        let client = HotSheetCLIClient(executable: cli, storePath: store, runner: runner, baseEnvironment: [:])
        #expect(try client.attachmentIDs(on: "HS-R5J6XP")["review.json"] == "01M4FS6YFMYB1HH8KGZV1H22CM")
        #expect(runner.calls.first?.arguments == [
            "-C", "/stores/demo.hs2", "show", "--actor-role=human", "--actor-id=ux-review", "HS-R5J6XP",
        ])
    }

    @Test func annotateWritesTheProjectionAsSnakeCaseJSON() throws {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: "Updated annotations for a.png (01M4)\n", stderr: "")])
        var written: [[String: Any]] = []
        runner.onRun = { call in
            guard let flag = call.arguments.first(where: { $0.hasPrefix("--file=") }),
                  let data = FileManager.default.contents(atPath: String(flag.dropFirst("--file=".count))),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            written = json
        }
        let client = HotSheetCLIClient(executable: cli, storePath: store, runner: runner, baseEnvironment: [:])
        let annotations = [
            HotSheetMediaAnnotation(id: "a1", x: 1, y: 2, width: 3, height: 4, startMs: 5, endMs: 6, text: "#1 [bug] n"),
            HotSheetMediaAnnotation(id: "a2", x: 7, y: 8, width: 9, height: 10, startMs: nil, endMs: nil, text: ""),
        ]
        try client.annotate(annotations, attachmentID: "01M4ATT", on: "HS-1")

        let args = try #require(runner.calls.first?.arguments)
        #expect(Array(args.prefix(6)) == ["-C", "/stores/demo.hs2", "annotate", "--actor-role=human", "--actor-id=ux-review", "HS-1"])
        #expect(args[6] == "01M4ATT")
        #expect(args[7].hasPrefix("--file=") && args.count == 8)
        // The temporary JSON is gone once the CLI has read it.
        #expect(!FileManager.default.fileExists(atPath: String(args[7].dropFirst("--file=".count))))
        #expect(written.count == 2)
        #expect(written.first?["start_ms"] as? Int == 5 && written.first?["end_ms"] as? Int == 6)
        #expect(written.first?["text"] as? String == "#1 [bug] n" && written.first?["width"] as? Int == 3)
        #expect(written.last?["start_ms"] == nil)
    }

    @Test func aCLIWithoutAnnotateReportsUnsupported() {
        let old = FakeRunner(results: [ProcessResult(
            exitCode: 2, stdout: "", stderr: "error: unrecognized subcommand 'annotate'\n\nUsage: hotsheet-cli [OPTIONS] <COMMAND>\n"
        )])
        let client = HotSheetCLIClient(executable: cli, storePath: store, runner: old, baseEnvironment: [:])
        #expect(throws: HotSheetError.annotationsUnsupported) {
            try client.annotate([], attachmentID: "X", on: "HS-1")
        }
        let failing = FakeRunner(results: [ProcessResult(exitCode: 1, stdout: "", stderr: "Error: annotations require unique ids")])
        let other = HotSheetCLIClient(executable: cli, storePath: store, runner: failing, baseEnvironment: [:])
        #expect(throws: HotSheetError.commandFailed(command: "annotate", exitCode: 1, stderr: "Error: annotations require unique ids")) {
            try other.annotate([], attachmentID: "X", on: "HS-1")
        }
    }

    // MARK: Submitter

    /// The example bundle (5 annotations on capture-1.png, 1 on capture-2.mov) in a media folder.
    private func exampleFixture() throws -> (ReviewBundle, URL) {
        let bundle = try TestSupport.exampleBundle()
        let dir = try TestSupport.makeTempDirectory()
        for item in bundle.media {
            try Data("bytes".utf8).write(to: dir.appendingPathComponent(item.filename))
        }
        return (bundle, dir)
    }

    @Test func aNewTicketGetsEachAnnotatedCapturesProjection() throws {
        let (bundle, dir) = try exampleFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = FakeHotSheetClient()
        try ReviewSubmitter(client: client).submit(bundle, mediaDirectory: dir)

        let projection = TicketComposer.compose(bundle).hotSheetAnnotations
        #expect(client.annotated.map(\.filename) == ["capture-1.png", "capture-2.mov"])
        #expect(client.annotated.allSatisfy { $0.slug == "HS-TEST01" })
        #expect(client.annotated.first?.annotations == projection["m1"])
        #expect(client.annotated.last?.annotations == projection["m2"])
        #expect(client.annotated.first?.annotations.map(\.id) == ["a1", "a2", "a3", "a4", "a6"])
    }

    @Test func capturesWithoutAnnotationsAndReviewJSONAreLeftAlone() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["shot.png", "clip.mov"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        let bundle = TestSupport.bundle(media: [TestSupport.image(), TestSupport.video()], annotations: [
            Annotation(id: "a", mediaId: "v1", shape: .rect(NormRect(x: 0, y: 0, width: 10, height: 10)), note: "n"),
        ])
        let client = FakeHotSheetClient()
        try ReviewSubmitter(client: client).submit(bundle, mediaDirectory: dir)
        #expect(client.annotated.map(\.filename) == ["clip.mov"])

        // No annotations at all: nothing to look up or write.
        let plain = FakeHotSheetClient()
        plain.attachmentIDsError = HotSheetError.cliNotFound
        try ReviewSubmitter(client: plain).submit(TestSupport.bundle(), mediaDirectory: dir)
        #expect(plain.annotated.isEmpty)
    }

    @Test func annotationProblemsNeverFailTheSubmission() throws {
        let (bundle, dir) = try exampleFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        // An old CLI: filed, no regions.
        let old = FakeHotSheetClient()
        old.annotationSupport = false
        #expect(try ReviewSubmitter(client: old).submit(bundle, mediaDirectory: dir) == "HS-TEST01")
        #expect(old.annotated.isEmpty && old.attached.count == 1)

        // `show` fails: filed, no regions.
        let blind = FakeHotSheetClient()
        blind.attachmentIDsError = HotSheetError.commandFailed(command: "show", exitCode: 1, stderr: "x")
        #expect(try ReviewSubmitter(client: blind).submit(bundle, mediaDirectory: dir) == "HS-TEST01")
        #expect(blind.annotated.isEmpty)

        // One capture's write fails: the next one is still written.
        let flaky = FakeHotSheetClient()
        flaky.annotateErrors = [HotSheetError.commandFailed(command: "annotate", exitCode: 1, stderr: "invalid")]
        #expect(try ReviewSubmitter(client: flaky).submit(bundle, mediaDirectory: dir) == "HS-TEST01")
        #expect(flaky.annotated.map(\.filename) == ["capture-2.mov"])
    }

    @Test func unsupportedStopsAfterTheFirstTry() throws {
        let (bundle, dir) = try exampleFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = FakeHotSheetClient()
        // The first capture fails as unsupported; the second would succeed but is never tried.
        client.annotateErrors = [HotSheetError.annotationsUnsupported]
        try ReviewSubmitter(client: client).submit(bundle, mediaDirectory: dir)
        #expect(client.annotated.isEmpty)
    }

    @Test func anExistingTicketIsAnnotatedUnderTheRenamedFilesThenNoted() throws {
        let (bundle, dir) = try exampleFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = FakeHotSheetClient()
        client.existingNames = ["capture-1.png"]
        let ticket = CreatedTicket(slug: "HS-OLD001")
        _ = try ReviewSubmitter(client: client).add(bundle, mediaDirectory: dir, to: ticket)
        #expect(client.annotated.map(\.filename) == ["capture-1 (2).png", "capture-2.mov"])
        #expect(client.annotated.allSatisfy { $0.slug == "HS-OLD001" })
        #expect(client.notes.count == 1)

        // Retrying only the note doesn't write the annotations again.
        let retry = FakeHotSheetClient()
        retry.existingNames = ["capture-1.png", "capture-1 (2).png", "capture-2.mov", "review.json"]
        _ = try ReviewSubmitter(client: retry).add(
            bundle, mediaDirectory: dir, to: ticket, attached: ["capture-1.png": "capture-1 (2).png"]
        )
        #expect(retry.annotated.isEmpty && retry.notes.count == 1)
    }

    @Test func aResumedAttachAnnotatesFilesFromBothTries() throws {
        let (bundle, dir) = try exampleFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = FakeHotSheetClient()
        client.attachErrors = [HotSheetError.attachIncomplete(storedNames: ["_"], exitCode: 1, stderr: "disk")]
        let submitter = ReviewSubmitter(client: client, makeBatchID: { "batch-1" })

        // 1. Only capture-1.png gets in: no annotations yet, the attach failed.
        let failure = try #require(throws: ReviewSubmissionError.self) {
            try submitter.file(bundle, mediaDirectory: dir)
        }
        guard case let .attachFailed(ticket, _, partial) = failure else {
            Issue.record("expected attachFailed, got \(failure)")
            return
        }
        #expect(client.annotated.isEmpty)

        // 2. The resume attaches the rest; both captures are annotated, the first by its earlier id.
        _ = try submitter.file(bundle, mediaDirectory: dir, existingTicket: ticket, resume: partial)
        #expect(client.annotated.map(\.filename) == ["capture-1.png", "capture-2.mov"])
    }
}
