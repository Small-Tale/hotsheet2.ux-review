import Foundation
import Testing
@testable import UXReviewKit

/// Delete Immediately when the Trash refuses a draft (docs/07 §7.9, `HS2-N10RZS`): Trash refused →
/// deleted → refilled, deleting older and broken drafts, a deletion that fails part-way, and
/// which errors offer deletion. Uses `DraftListingTests.Fixture`.
extension DraftListingTests {
    /// The Trash refuses → the draft is kept, and the error offers deletion → Delete
    /// Immediately removes it for good, clears the pointer, and leaves other drafts alone → the
    /// next capture starts a new draft → deleting it again is noSuchDraft.
    @Test func whenTheTrashRefusesTheDraftCanBeDeletedImmediately() throws {
        let base = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let blocker = base.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let fixture = try Fixture(trash: .folder(blocker.appendingPathComponent("Trash")))
        let older = try fixture.capture(2)
        try fixture.store.startNew()
        let draft = try fixture.capture()

        let refused = try #require(throws: ReviewDraftError.self) { try fixture.store.discard(draft.directory) }
        #expect(refused.canDeleteInstead)
        #expect(fixture.exists(draft.bundleURL) && fixture.store.isCurrent(draft.directory))

        let deleted = try fixture.store.discard(draft.directory, deleteImmediately: true)
        #expect(deleted == DiscardedDraft(directory: draft.directory, trashedTo: nil, wasCurrent: true, deleted: true))
        #expect(!fixture.exists(draft.directory))
        #expect(!fixture.exists(fixture.root.appendingPathComponent("current")))
        #expect(try fixture.store.listDrafts().map(\.name) == [older.directory.lastPathComponent])
        #expect(fixture.exists(older.bundleURL))

        let next = try fixture.capture()
        #expect(next.directory != draft.directory && next.directory != older.directory)
        #expect(throws: ReviewDraftError.noSuchDraft(draft.directory)) {
            try fixture.store.discard(draft.directory, deleteImmediately: true)
        }
    }

    /// Deleting an older draft (and a broken one) immediately keeps the current draft, and never
    /// touches the Trash folder.
    @Test func deletingImmediatelyBypassesTheTrash() throws {
        let fixture = try Fixture()
        let older = try fixture.capture()
        try fixture.store.startNew()
        let current = try fixture.capture()
        let broken = fixture.root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)

        #expect(try !fixture.store.discard(older.directory, deleteImmediately: true).wasCurrent)
        #expect(try fixture.store.discard(broken, deleteImmediately: true).deleted)
        #expect(!fixture.exists(older.directory) && !fixture.exists(broken))
        #expect(fixture.store.isCurrent(current.directory))
        #expect(!fixture.exists(fixture.trashFolder))
    }

    /// A deletion the file system refuses part-way (a read-only drafts folder: the files inside
    /// go, the folder can't) keeps the folder and its pointer, so it is still listed (as broken)
    /// and can be deleted again once the folder is writable.
    @Test func aFailedDeletionKeepsTheDraft() throws {
        let fixture = try Fixture()
        let draft = try fixture.capture()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path) }
        let error = try #require(throws: ReviewDraftError.self) {
            try fixture.store.discard(draft.directory, deleteImmediately: true)
        }
        guard case .deleteFailed = error else { Issue.record("expected deleteFailed, got \(error)"); return }
        #expect(!error.canDeleteInstead)
        // review.json went with the other files, so the draft lists as broken but still current.
        let listed = try fixture.store.listDrafts()
        #expect(listed.map(\.name) == [draft.directory.lastPathComponent])
        #expect(listed.first?.isCurrent == true && listed.first?.isReadable == false)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
        #expect(try fixture.store.discard(draft.directory, deleteImmediately: true).wasCurrent)
        #expect(!fixture.exists(draft.directory))
    }

    @Test func onlyATrashFailureOffersDeletion() {
        let url = URL(fileURLWithPath: "/d/x")
        let errors: [ReviewDraftError] = [
            .missingCaptureFile(url), .unreadableDraft(url), .unknownMedia("m1"), .outsideDrafts(url),
            .noSuchDraft(url), .deleteFailed(url, "no"),
        ]
        #expect(errors.allSatisfy { !$0.canDeleteInstead })
        #expect(ReviewDraftError.trashFailed(url, "no").canDeleteInstead)
        #expect(ReviewDraftError.trashFailed(url, "No Trash here.").trashRefusal == "No Trash here.")
        #expect(ReviewDraftError.deleteFailed(url, "no").trashRefusal == nil)
        #expect(ReviewDraftError.deleteFailed(url, "Permission denied").description == "x couldn't be deleted: Permission denied")
    }
}
