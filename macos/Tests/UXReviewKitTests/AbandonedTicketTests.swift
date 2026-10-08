import Foundation
import Testing
@testable import UXReviewKit

/// A ticket a failed New ticket try created, left behind when the review then goes to an existing
/// ticket (HS2-3SVGZ3, docs/07 §7.5): named in the result so the window can offer to trash it.
struct AbandonedTicketTests {
    typealias Fixture = DraftSubmitterTests.Fixture
    static let existing = ExistingTicketSubmitterTests.existing

    @Test func aFailedNewTicketTryIsNamedAfterAddingToAnExistingTicket() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 1)
        fixture.client.attachErrors = [HotSheetError.commandFailed(command: "attach", exitCode: 1, stderr: "locked")]
        #expect(throws: SubmissionFailure.self) { try fixture.submitter().submit(draft.directory) }
        let result = try fixture.submitter().submit(draft.directory, into: Self.existing)
        #expect(result.abandonedTicket == "HS-TEST01" && result.ticket.slug == "HS-OLD001")
        #expect(fixture.client.trashed.isEmpty) // only offered, never done on its own
    }

    /// Partly attached counts too; a record of the existing ticket itself, no record, or a record
    /// in another store does not.
    @Test func onlyACreatedTicketInThisStoreIsNamed() throws {
        let partly = try Fixture()
        let one = try partly.draft(captures: 2)
        partly.client.attachErrors = [PartialAttachTests.stopsAfter(1)]
        #expect(throws: SubmissionFailure.self) { try partly.submitter().submit(one.directory) }
        #expect(try partly.submitter().submit(one.directory, into: Self.existing).abandonedTicket == "HS-TEST01")

        let own = try Fixture()
        let two = try own.draft(captures: 1)
        own.client.noteErrors = [HotSheetError.commandFailed(command: "edit", exitCode: 1, stderr: "busy")]
        #expect(throws: SubmissionFailure.self) { try own.submitter().submit(two.directory, into: Self.existing) }
        #expect(try own.submitter().submit(two.directory, into: Self.existing).abandonedTicket == nil)

        let clean = try Fixture()
        #expect(try clean.submitter().submit(clean.draft(captures: 1).directory, into: Self.existing).abandonedTicket == nil)

        let elsewhere = try Fixture()
        let three = try elsewhere.draft(captures: 1)
        elsewhere.client.attachErrors = [HotSheetError.cliNotFound]
        #expect(throws: SubmissionFailure.self) { try elsewhere.submitter(URL(fileURLWithPath: "/stores/b.hs2")).submit(three.directory) }
        #expect(try elsewhere.submitter().submit(three.directory, into: Self.existing).abandonedTicket == nil)
    }

    @Test func moveToTrashEditsTheStatus() throws {
        let runner = FakeRunner(results: [])
        let client = HotSheetCLIClient(
            executable: URL(fileURLWithPath: "/bin/hs"), storePath: URL(fileURLWithPath: "/stores/demo.hs2"), runner: runner
        )
        try client.moveToTrash("HS-1")
        #expect(runner.calls.first?.arguments == [
            "-C", "/stores/demo.hs2", "edit", "--actor-role=human", "--actor-id=ux-review", "HS-1", "--status=deleted",
        ])
    }
}

extension HotSheetEndToEndTests {
    /// The real CLI: a New ticket try whose attach fails, then Add to existing ticket names the
    /// created ticket, and moving it to the Trash sets `status: deleted`.
    @Test(.enabled(if: cli != nil, "hotsheet-cli not installed"), .timeLimit(.minutes(2)))
    func anAbandonedTicketCanBeTrashed() throws {
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
        let target = try #require(try client.findTicket(client.createTicketReportingFile(NewTicket(title: "Target", details: "x")).slug))

        let drafts = ReviewDraftStore(root: root.appendingPathComponent("Drafts"))
        let draft = try Self.imageAndVideoDraft(in: drafts, raw: root)
        let image = draft.appendingPathComponent("capture-1.png")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: image.path)
        let submitter = DraftSubmitter(store: drafts, client: client, storePath: store)
        let failure = try #require(throws: SubmissionFailure.self) { try submitter.submit(draft, title: "Lost") }
        let created = try #require(failure.createdTicket)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: image.path)

        let result = try submitter.submit(draft, title: "Lost", into: target)
        #expect(result.abandonedTicket == created)
        #expect(try hs("show", created).stdout.contains("status: not_started"))
        try client.moveToTrash(created)
        #expect(try hs("show", created).stdout.contains("status: deleted"))
    }
}
