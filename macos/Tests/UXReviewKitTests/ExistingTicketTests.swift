import Foundation
import Testing
@testable import UXReviewKit

/// Adding a review to an existing ticket (HS2-E3001H, docs/03 §3.5, docs/07 §7.2.1): reading what
/// the reviewer typed, `hotsheet-cli show` / `attach` / `edit` through a faithful fake runner,
/// the note, and the submitter's resume rules.
struct TicketReferenceTests {
    @Test(arguments: [
        ("HS2-E3001H", "HS2-E3001H"),
        ("  hs-ycdz2a \n", "HS-YCDZ2A"),
        ("HS-ABCDEF", "HS-ABCDEF"), // a slug with no digit, typed alone
        ("`HS-YCDZ2A`", "HS-YCDZ2A"),
        ("#HS-YCDZ2A", "HS-YCDZ2A"),
        (" ● HS-YCDZ2A    not_started  Existing one", "HS-YCDZ2A"), // a line from `hotsheet-cli ls`
        ("HS-YCDZ2A: Existing one", "HS-YCDZ2A"),
        ("see the ux-review follow-up HS-ABCDEF", "HS-ABCDEF"),
        ("ux-review notes for hs2-e3001h", "HS2-E3001H"),
        ("01M4CCW6AW9EHFYT2QTZJ70H8D", "01M4CCW6AW9EHFYT2QTZJ70H8D"),
        ("01m4ccw6aw9ehfyt2qtzj70h8d", "01M4CCW6AW9EHFYT2QTZJ70H8D"),
        ("/s/app.hs2/tickets/8D/01M4CCW6AW9EHFYT2QTZJ70H8D.md", "01M4CCW6AW9EHFYT2QTZJ70H8D"),
        ("http://localhost:4174/tickets/HS-YCDZ2A", "HS-YCDZ2A"),
    ])
    func parsesWhatReviewersPaste(input: String, expected: String) {
        #expect(TicketReference.parse(input) == expected)
    }

    @Test(arguments: ["", "   ", "nothing here", "ux-review follow-up", "HS-", "-ABC123", "HS-12", "a-b-c", "HS‐ABC123"])
    func rejectsTextWithoutATicket(input: String) {
        #expect(TicketReference.parse(input) == nil)
    }
}

struct HotSheetTicketParsingTests {
    static let show = """
    ---
    id: 01M4CCW6AW9EHFYT2QTZJ70H8D
    slug: HS-YCDZ2A
    title: 'UX review: a "quoted" title — it''s fine'
    category: task
    priority: default
    status: not_started
    attachments:
    - id: 01M4CCYYFVGXYP8ZCCJGWCYHJS
      filename: review.json
      status: deleted
    schema: hotsheet/v2-bounded-notes
    ---

    <!-- hotsheet:body:begin -->
    title: not front matter
    <!-- hotsheet:body:end -->
    """

    @Test func readsFrontMatterScalars() {
        #expect(HotSheetTicket.parseShow(Self.show) == HotSheetTicket(
            id: "01M4CCW6AW9EHFYT2QTZJ70H8D", slug: "HS-YCDZ2A",
            title: "UX review: a \"quoted\" title — it's fine", status: "not_started"
        ))
    }

    @Test func yamlScalarForms() {
        #expect(YAMLScalar.parse(" plain value ") == "plain value")
        #expect(YAMLScalar.parse("plain # comment") == "plain")
        #expect(YAMLScalar.parse("'it''s'") == "it's")
        #expect(YAMLScalar.parse(#""tab\there \"q\" é""#) == "tab\there \"q\" é")
        #expect(YAMLScalar.parse("''") == "")
    }

    @Test func outputWithoutFrontMatterOrIdIsNil() {
        #expect(HotSheetTicket.parseShow("Updated HS-1\n") == nil)
        #expect(HotSheetTicket.parseShow("---\ntitle: x\n---\n") == nil)
    }

    @Test func closedStatusesRefuseReviews() {
        var ticket = HotSheetTicket(id: "X", slug: "HS-1", title: "t", status: "completed")
        #expect(ticket.acceptsReviews)
        for status in ["deleted", "moved"] {
            ticket.status = status
            #expect(!ticket.acceptsReviews)
        }
    }

    @Test func ticketFileFollowsTheStoreLayout() {
        #expect(
            HotSheetTicket.ticketFile(id: "01M4CCW6AW9EHFYT2QTZJ70H8D", store: URL(fileURLWithPath: "/s/a.hs2")).path
                == "/s/a.hs2/tickets/8D/01M4CCW6AW9EHFYT2QTZJ70H8D.md"
        )
    }
}

struct ExistingTicketCLITests {
    private let cli = URL(fileURLWithPath: "/bin/hotsheet-cli")

    private func client(_ runner: FakeRunner, store: URL = URL(fileURLWithPath: "/stores/demo.hs2")) -> HotSheetCLIClient {
        HotSheetCLIClient(executable: cli, storePath: store, runner: runner, baseEnvironment: [:])
    }

    @Test func findTicketRunsShowAndReportsTheFileWhenItExists() throws {
        let store = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: store) }
        let file = HotSheetTicket.ticketFile(id: "01M4CCW6AW9EHFYT2QTZJ70H8D", store: store)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: HotSheetTicketParsingTests.show, stderr: "")])
        let ticket = try #require(try client(runner, store: store).findTicket("HS-YCDZ2A"))
        #expect(ticket.slug == "HS-YCDZ2A" && ticket.file == file.path)
        #expect(runner.calls.first?.arguments == ["-C", store.path, "show", "--actor-role=human", "--actor-id=ux-review", "HS-YCDZ2A"])

        // No file on disk: no "Show Ticket File".
        let other = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: HotSheetTicketParsingTests.show, stderr: "")])
        #expect(try client(other).findTicket("HS-YCDZ2A")?.file == nil)
    }

    @Test func findTicketNotFoundIsNilAndOtherFailuresThrow() throws {
        let missing = FakeRunner(results: [ProcessResult(exitCode: 1, stdout: "", stderr: "Error: no ticket matching 'HS-NOPE00'\n")])
        #expect(try client(missing).findTicket("HS-NOPE00") == nil)
        let broken = FakeRunner(results: [ProcessResult(exitCode: 2, stdout: "", stderr: "store is locked")])
        #expect(throws: HotSheetError.commandFailed(command: "show", exitCode: 2, stderr: "store is locked")) {
            try client(broken).findTicket("HS-1")
        }
        let odd = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: "hello", stderr: "")])
        #expect(throws: HotSheetError.unexpectedOutput(command: "show", stdout: "hello")) { try client(odd).findTicket("HS-1") }
    }

    /// The real CLI's output (HS2-E3001H probe): one `Attached …` and one `Durable attachment id`
    /// line per file, renamed when the ticket already has the name, Markdown-quoted when needed.
    @Test func attachReportsStoredNamesFromTheRealOutputShape() throws {
        let stdout = """
        Attached attachment:capture-1.png
        Durable attachment id: 01M4CCZJF6BG9GXSV0VF9Y2MAZ (/s/a.hs2/attachments/01M4/01M4CCZJF6BG9GXSV0VF9Y2MAZ/capture-1.png)
        Attached ``attachment:we`ird.png``
        Durable attachment id: 01M4CCZJPXG56PDABGCYAYT5N7 (/s/a.hs2/attachments/01M4/01M4CCZJPXG56PDABGCYAYT5N7/we`ird.png)
        Attached `attachment:review (3).json`
        Durable attachment id: 01M4CCZJV0E6Z961Y5SRYVHS20 (/s/a.hs2/attachments/01M4/01M4CCZJV0E6Z961Y5SRYVHS20/review (3).json)

        """
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: stdout, stderr: "")])
        let files = ["capture-1.png", "we`ird.png", "review.json"].map { URL(fileURLWithPath: "/d/\($0)") }
        let names = try client(runner).attachReportingNames(
            files: files,
            to: "HS-1",
            batchLabel: "UX review capture",
            purpose: "problem_evidence",
            batchID: nil
        )
        #expect(names == ["capture-1.png", "we`ird.png", "review (3).json"])
        #expect(runner.calls.first?.arguments.suffix(4) == ["--", "/d/capture-1.png", "/d/we`ird.png", "/d/review.json"])

        // Output it can't read (an older CLI): assume the files kept their names.
        let quiet = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: "ok\n", stderr: "")])
        #expect(
            try client(quiet).attachReportingNames(files: files, to: "HS-1", batchLabel: nil, purpose: nil, batchID: nil)
                == ["capture-1.png", "we`ird.png", "review.json"]
        )
    }

    /// The real CLI stopping part-way (HS2-QNWMKF probe: a missing second file): the first file's
    /// lines, then `Error: …` on stderr and exit 1. The names printed so far come back in
    /// `attachIncomplete`; a batch id is passed through as `--batch-id`.
    @Test func aPartialAttachReportsWhatGotIn() throws {
        let stdout = """
        Attached `attachment:capture-1 (2).png`
        Durable attachment id: 01M4CHK3QMFMBFK9SEWMXSV8TY (/s/a.hs2/attachments/01M4/01M4CHK3QMFMBFK9SEWMXSV8TY/capture-1 (2).png)

        """
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: stdout, stderr: "Error: No such file or directory (os error 2)\n"),
        ])
        let files = ["capture-1.png", "capture-2.mov", "review.json"].map { URL(fileURLWithPath: "/d/\($0)") }
        #expect(throws: HotSheetError.attachIncomplete(
            storedNames: ["capture-1 (2).png"], exitCode: 1, stderr: "Error: No such file or directory (os error 2)\n"
        )) {
            try client(runner).attachReportingNames(files: files, to: "HS-1", batchLabel: "L", purpose: nil, batchID: "batch-x")
        }
        #expect(runner.calls.first?.arguments.contains("--batch-id=batch-x") == true)
        #expect(
            ReviewSubmitter.describe(HotSheetError.attachIncomplete(storedNames: ["a"], exitCode: 1, stderr: "Error: gone\n"))
                == "hotsheet-cli attach failed after attaching 1 file (exit 1): Error: gone"
        )

        // A failure before any file: the usual commandFailed, and no --batch-id without one.
        let early = FakeRunner(results: [ProcessResult(exitCode: 1, stdout: "", stderr: "Error: no ticket\n")])
        #expect(throws: HotSheetError.commandFailed(command: "attach", exitCode: 1, stderr: "Error: no ticket\n")) {
            try client(early).attachReportingNames(files: files, to: "HS-9", batchLabel: nil, purpose: nil, batchID: nil)
        }
        #expect(early.calls.first?.arguments.contains { $0.hasPrefix("--batch-id") } == false)
    }

    @Test func addNoteWritesAFileAndRunsEditWithNoteFile() throws {
        final class Capturing: ProcessRunning, @unchecked Sendable {
            var arguments: [String] = []
            var noteText: String?
            func run(
                executable _: URL,
                arguments: [String],
                environment _: [String: String],
                currentDirectory _: URL?
            ) throws -> ProcessResult {
                self.arguments = arguments
                if let flag = arguments.first(where: { $0.hasPrefix("--note-file=") }) {
                    noteText = try String(contentsOfFile: String(flag.dropFirst("--note-file=".count)), encoding: .utf8)
                }
                return ProcessResult(exitCode: 0, stdout: "Updated HS-YCDZ2A\n", stderr: "")
            }
        }
        let runner = Capturing()
        let client = HotSheetCLIClient(executable: cli, storePath: URL(fileURLWithPath: "/s.hs2"), runner: runner, baseEnvironment: [:])
        try client.addNote("## Note\n\n-starts with a dash\n", to: "HS-YCDZ2A")
        #expect(runner.noteText == "## Note\n\n-starts with a dash\n")
        #expect(Array(runner.arguments.prefix(6)) == ["-C", "/s.hs2", "edit", "--actor-role=human", "--actor-id=ux-review", "HS-YCDZ2A"])
        let file = try #require(runner.arguments.last?.dropFirst("--note-file=".count))
        #expect(!FileManager.default.fileExists(atPath: String(file)), "the note file is removed afterwards")
    }

    @Test func addNoteFailureSurfacesStderr() {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 1, stdout: "", stderr: "Error: no ticket matching 'HS-1'")])
        #expect(throws: HotSheetError.commandFailed(command: "edit", exitCode: 1, stderr: "Error: no ticket matching 'HS-1'")) {
            try client(runner).addNote("x", to: "HS-1")
        }
    }

    @Test func submitCommandToTicket() throws {
        #expect(try SubmitCommand.parse(["--submit", "--to-ticket", "hs-ycdz2a"])?.toTicket == "hs-ycdz2a")
        #expect(throws: CommandLineError.invalidValue("--to-ticket", "nothing")) {
            try SubmitCommand.parse(["--submit", "--to-ticket", "nothing"])
        }
        #expect(throws: CommandLineError.missingValue("--to-ticket")) { try SubmitCommand.parse(["--submit", "--to-ticket"]) }
    }
}

struct ExistingTicketNoteTests {
    static func bundle() -> ReviewBundle {
        var bundle = TestSupport.bundle(
            media: [TestSupport.image("m1", filename: "capture-1.png"), TestSupport.video("m2", filename: "capture-2.mov")],
            annotations: [
                Annotation(
                    id: "a1",
                    mediaId: "m1",
                    shape: .rect(NormRect(x: 0, y: 0, width: 100, height: 100)),
                    intents: [.bug],
                    note: "Clipped"
                ),
                Annotation(
                    id: "a2",
                    mediaId: "m2",
                    shape: .insertion(NormPoint(x: 10, y: 10)),
                    note: "",
                    timeRange: TimeRange(startMs: 500, endMs: 1500)
                ),
            ]
        )
        bundle.title = "Checkout polish"
        bundle.summary = "Two things on checkout."
        return bundle
    }

    @Test func noteHasTheReviewSectionsWithoutIntakeInstructions() {
        let note = TicketComposer.note(for: Self.bundle())
        #expect(
            note
                .hasPrefix("## UX review: Checkout polish\n\nFeedback on this ticket, added with UX Review: 2 captures and 2 annotations.")
        )
        #expect(note.contains("`attachment:review.json` is the canonical"))
        #expect(note.contains("### Reviewer summary\n\nTwo things on checkout."))
        #expect(note.contains("### Media\n\n- `attachment:capture-1.png` (image, 100×50)"))
        #expect(note.contains("#### #1 · bug · `attachment:capture-1.png`"))
        #expect(note.contains("#### #2 · insert · `attachment:capture-2.mov`\n\n- Shape: insertion"))
        #expect(note.contains("- Time: 0:00.500–0:01.500"))
        #expect(note.contains("_No note._"))
        #expect(!note.contains("Instructions for the AI"))
        #expect(!note.contains("\n## Media"))
    }

    @Test func noteCitesRenamedAttachmentsByTheirStoredNames() {
        let note = TicketComposer.note(
            for: Self.bundle(),
            storedNames: ["capture-1.png": "capture-1 (2).png", "review.json": "review (2).json"]
        )
        #expect(note.contains("`attachment:review (2).json` is the canonical"))
        #expect(
            note
                .contains(
                    "- `attachment:capture-1 (2).png` (image, 100×50); stored under this name, `review.json` calls it `capture-1.png`"
                )
        )
        #expect(note.contains("#### #1 · bug · `attachment:capture-1 (2).png`"))
        #expect(note.contains("#### #2 · insert · `attachment:capture-2.mov`"))
    }

    @Test func intakeBodyIsUnchangedByTheSharedSections() {
        let details = TicketComposer.compose(Self.bundle()).ticket.details
        #expect(details.contains("## Reviewer summary\n\nTwo things on checkout."))
        #expect(details.contains("### #1 · bug · `attachment:capture-1.png`"))
        #expect(details.contains("## Media\n\n- `attachment:capture-1.png` (image, 100×50)"))
    }

    @Test func codeSpansFenceBackticks() {
        #expect(TicketComposer.attachmentReference("a.png") == "`attachment:a.png`")
        #expect(TicketComposer.attachmentReference("we`ird.png") == "``attachment:we`ird.png``")
        #expect(TicketComposer.codeSpan("`x") == "`` `x ``")
    }
}
