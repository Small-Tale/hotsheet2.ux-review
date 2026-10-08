import Foundation
import Testing
@testable import UXReviewKit

/// `hotsheet-cli attach` is not atomic (HS2-QNWMKF, docs/07 §7.5): an attach that stops part-way
/// is recorded in submission.json, and each retry attaches only the files still missing, into
/// the same batch. Walks partial → partial → nothing → success for a new ticket, partial → note
/// failure → note for an existing ticket, and records that must not cross between the two.
struct PartialAttachTests {
    typealias Fixture = DraftSubmitterTests.Fixture

    /// Stops after `count` files, like the CLI on a missing or unreadable file.
    static func stopsAfter(_ count: Int) -> HotSheetError {
        .attachIncomplete(storedNames: Array(repeating: "_", count: count), exitCode: 1, stderr: "Error: gone")
    }

    /// Hands out `batch-1`, `batch-2`, … so a new batch is visible.
    final class BatchIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return "batch-\(count)"
        }
    }

    static func submitter(_ fixture: Fixture, _ ids: BatchIDs) -> DraftSubmitter {
        DraftSubmitter(
            store: fixture.store, client: fixture.client, storePath: fixture.storePath,
            now: { Date(timeIntervalSince1970: 5000) }, makeBatchID: { ids.next() }
        )
    }

    static let existing = ExistingTicketSubmitterTests.existing

    /// Every file name attached so far, in order.
    static func attachedNames(_ fixture: Fixture) -> [String] {
        fixture.client.attached.flatMap { $0.files.map(\.lastPathComponent) }
    }

    @Test func aNewTicketResumesEachPartialAttachIntoTheSameBatch() throws {
        let fixture = try Fixture()
        let ids = BatchIDs()
        let draft = try fixture.draft(captures: 2)
        fixture.client.attachErrors = [
            Self.stopsAfter(1),
            Self.stopsAfter(1),
            HotSheetError.commandFailed(command: "attach", exitCode: 1, stderr: "locked"),
        ]

        // 1. Created, then the attach stops after capture-1.png.
        let first = try #require(throws: SubmissionFailure.self) { try Self.submitter(fixture, ids).submit(draft.directory) }
        #expect(first.createdTicket == "HS-TEST01" && first.partlyAttached)
        #expect(
            first.message == "HS-TEST01 was created, but attaching the media failed: "
                + "hotsheet-cli attach failed after attaching 1 file (exit 1): Error: gone"
        )
        var pending = try #require(fixture.store.pendingSubmission(in: draft.directory))
        #expect(pending.partialAttach == PartialAttach(batchID: "batch-1", storedNames: ["capture-1.png": "capture-1.png"]))
        #expect(pending.isPartlyAttached && !pending.isForExistingTicket)
        let row = try #require(fixture.store.listDrafts().first)
        #expect(row.pendingTicket == "HS-TEST01" && row.pendingPartlyAttached && !row.pendingToExisting && !row.pendingNoteOnly)

        // 2. The retry attaches only the rest, into batch-1, and stops again after one file.
        #expect(throws: SubmissionFailure.self) { try Self.submitter(fixture, ids).submit(draft.directory) }
        pending = try #require(fixture.store.pendingSubmission(in: draft.directory))
        #expect(pending.partialAttach?.storedNames.keys.sorted() == ["capture-1.png", "capture-2.mov"])
        #expect(pending.partialAttach?.batchID == "batch-1")

        // 3. A failure that attaches nothing keeps the record as it was.
        let third = try #require(throws: SubmissionFailure.self) { try Self.submitter(fixture, ids).submit(draft.directory) }
        #expect(third.partlyAttached)
        #expect(fixture.store.pendingSubmission(in: draft.directory) == pending)

        // 4. Success: only review.json is left; still one ticket, one batch, no file twice.
        let result = try Self.submitter(fixture, ids).submit(draft.directory)
        #expect(result.ticket.slug == "HS-TEST01" && result.draftRemoved)
        #expect(fixture.client.created.count == 1)
        #expect(Self.attachedNames(fixture) == ["capture-1.png", "capture-2.mov", "review.json"])
        #expect(fixture.client.batchIDs == ["batch-1", "batch-1", "batch-1"])
    }

    @Test func anExistingTicketResumesThePartialAttachThenTheNote() throws {
        let fixture = try Fixture()
        let ids = BatchIDs()
        let draft = try fixture.draft(captures: 2)
        fixture.client.attachErrors = [Self.stopsAfter(2)]
        fixture.client.noteErrors = [HotSheetError.commandFailed(command: "edit", exitCode: 1, stderr: "busy")]
        fixture.client.existingNames = ["capture-1.png"]

        // 1. Two files get in; no note yet.
        let first = try #require(throws: SubmissionFailure.self) {
            try Self.submitter(fixture, ids).submit(draft.directory, into: Self.existing)
        }
        #expect(first.attachedTo == "HS-OLD001" && first.partlyAttached && first.createdTicket == nil)
        #expect(first.message.hasPrefix("Some of the media was attached to HS-OLD001 before attaching failed: "))
        let pending = try #require(fixture.store.pendingSubmission(in: draft.directory))
        #expect(pending.toExistingTicket == true && pending.isForExistingTicket && pending.isPartlyAttached && !pending.isNotePending)
        #expect(pending.partialAttach?.storedNames == ["capture-1.png": "capture-1 (2).png", "capture-2.mov": "capture-2.mov"])
        let row = try #require(fixture.store.listDrafts().first)
        #expect(row.pendingToExisting && row.pendingPartlyAttached && !row.pendingNoteOnly)
        #expect(fixture.client.notes.isEmpty)

        // 2. The retry attaches only review.json into batch-1; the note fails.
        let second = try #require(throws: SubmissionFailure.self) {
            try Self.submitter(fixture, ids).submit(draft.directory, into: Self.existing)
        }
        #expect(second.attachedTo == "HS-OLD001" && !second.partlyAttached)
        let notePending = try #require(fixture.store.pendingSubmission(in: draft.directory))
        #expect(notePending.isNotePending && notePending.partialAttach == nil && notePending.createdAt == pending.createdAt)
        #expect(notePending.attachedNames?.count == 3 && notePending.attachedNames?["capture-1.png"] == "capture-1 (2).png")

        // 3. Only the note; it cites the stored names from the first, interrupted attach.
        let result = try Self.submitter(fixture, ids).submit(draft.directory, into: Self.existing)
        #expect(result.addedToExistingTicket && result.draftRemoved)
        #expect(Self.attachedNames(fixture) == ["capture-1.png", "capture-2.mov", "review.json"])
        #expect(fixture.client.batchIDs == ["batch-1", "batch-1"])
        #expect(fixture.client.notes.count == 1)
        #expect(fixture.client.notes.first?.markdown.contains("capture-1 (2).png") == true)
    }

    /// A partial record is reused only for the same kind of submission, ticket, and store.
    @Test func partialRecordsDoNotCrossDestinations() throws {
        let fixture = try Fixture()
        let ids = BatchIDs()
        let draft = try fixture.draft(captures: 1)

        // Partly attached to an existing ticket, then filed as a new ticket: a fresh batch of everything.
        fixture.client.attachErrors = [Self.stopsAfter(1)]
        #expect(throws: SubmissionFailure.self) { try Self.submitter(fixture, ids).submit(draft.directory, into: Self.existing) }
        fixture.client.attachErrors = [Self.stopsAfter(1)]
        #expect(throws: SubmissionFailure.self) { try Self.submitter(fixture, ids).submit(draft.directory) }
        #expect(fixture.client.batchIDs == ["batch-1", "batch-2"])
        let created = try #require(fixture.store.pendingSubmission(in: draft.directory))
        #expect(created.ticket.slug == "HS-TEST01" && !created.isForExistingTicket)
        #expect(created.partialAttach?.batchID == "batch-2" && created.partialAttach?.storedNames.keys.sorted() == ["capture-1.png"])

        // That created-ticket record isn't resumed for an existing ticket: a new batch of everything.
        _ = try Self.submitter(fixture, ids).submit(draft.directory, into: Self.existing)
        #expect(fixture.client.batchIDs.last == "batch-3")
        #expect(fixture.client.attached.last?.files.map(\.lastPathComponent) == ["capture-1.png", "review.json"])
    }

    /// A partial record in another store is ignored: a new ticket, a new batch, everything attached.
    @Test func aPartialRecordInAnotherStoreStartsOver() throws {
        let fixture = try Fixture()
        let ids = BatchIDs()
        let draft = try fixture.draft(captures: 1)
        fixture.client.attachErrors = [Self.stopsAfter(1)]
        #expect(throws: SubmissionFailure.self) { try Self.submitter(fixture, ids).submit(draft.directory) }
        let other = DraftSubmitter(
            store: fixture.store, client: fixture.client, storePath: URL(fileURLWithPath: "/stores/b.hs2"),
            makeBatchID: { ids.next() }
        )
        let result = try other.submit(draft.directory)
        #expect(result.ticket.slug == "HS-TEST02")
        #expect(fixture.client.batchIDs == ["batch-1", "batch-2"])
        #expect(fixture.client.attached.last?.files.map(\.lastPathComponent) == ["capture-1.png", "review.json"])
    }
}
