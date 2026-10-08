import Foundation
import Testing
@testable import UXReviewKit

/// HS2-QNWMKF against the real `hotsheet-cli`: an unreadable second file stops `attach` after
/// the first, the record keeps what got in, and Try Again attaches only the rest into the same
/// batch, for a new ticket and for an existing one. No file is attached twice.
extension HotSheetEndToEndTests {
    @Test(.enabled(if: cli != nil, "hotsheet-cli not installed"), .timeLimit(.minutes(2)))
    func aPartialAttachResumesWithoutDuplicates() throws {
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
        let fileManager = FileManager.default

        /// Files a draft whose movie can't be read the first time, then can.
        func fileWithAnUnreadableMovie(into existing: HotSheetTicket?) throws -> (slug: String, pending: PendingSubmission) {
            try drafts.startNew()
            let draft = try Self.imageAndVideoDraft(in: drafts, raw: root)
            let movie = draft.appendingPathComponent("capture-2.mov")
            try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: movie.path)
            let submitter = DraftSubmitter(store: drafts, client: client, storePath: store)
            let failure = try #require(throws: SubmissionFailure.self) { try submitter.submit(draft, title: "Partial", into: existing) }
            #expect(failure.partlyAttached)
            let pending = try #require(drafts.pendingSubmission(in: draft))
            #expect(pending.partialAttach?.storedNames.keys.sorted() == ["capture-1.png"])

            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: movie.path)
            let result = try submitter.submit(draft, title: "Partial", into: existing)
            #expect(result.draftRemoved && result.ticket.slug == pending.ticket.slug)
            return (result.ticket.slug, pending)
        }

        /// The ticket's attachments: file name → batch id.
        func attachments(_ slug: String) throws -> [(name: String, batch: String)] {
            let show = try hs("show", slug)
            try #require(show.exitCode == 0, "show failed: \(show.stderr)")
            var result: [(String, String)] = []
            var name: String?
            for line in show.stdout.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if line.hasPrefix("filename: ") { name = String(line.dropFirst("filename: ".count)) }
                if line.hasPrefix("batch_id: "), let current = name {
                    result.append((current, String(line.dropFirst("batch_id: ".count))))
                    name = nil
                }
            }
            return result
        }

        // A new ticket: one ticket, three files, one batch.
        let (created, createdPending) = try fileWithAnUnreadableMovie(into: nil)
        let filed = try attachments(created)
        #expect(filed.map(\.name).sorted() == ["capture-1.png", "capture-2.mov", "review.json"])
        #expect(Set(filed.map(\.batch)) == [try #require(createdPending.partialAttach?.batchID)])
        #expect(try hs("ls").stdout.split(separator: "\n").count(where: { $0.contains("HS-") }) == 1)

        // The same draft shape added to that ticket: three more files (renamed), one more batch, one note.
        let existing = try #require(try client.findTicket(created))
        let (added, addedPending) = try fileWithAnUnreadableMovie(into: existing)
        #expect(added == created && addedPending.toExistingTicket == true)
        let all = try attachments(created)
        let second = all.filter { $0.batch == addedPending.partialAttach?.batchID }
        #expect(second.map(\.name).sorted() == ["capture-1 (2).png", "capture-2 (2).mov", "review (2).json"])
        #expect(all.count == 6)
        let show = try hs("show", created).stdout
        #expect(show.components(separatedBy: "## UX review: Partial").count == 2, "exactly one review note")
        #expect(try hs("ls").stdout.split(separator: "\n").count(where: { $0.contains("HS-") }) == 1)
    }
}
