import Foundation
import Testing
@testable import UXReviewKit

/// The staging directory's life cycle (docs/07 §7.5): a draft with several captures is filed
/// and deleted; failures keep it; an attach failure is resumed without a duplicate ticket.
/// Plus the store operations the session window uses (title/summary, remove a capture).
struct DraftSubmitterTests {
    final class Fixture {
        let base: URL
        let root: URL
        let store: ReviewDraftStore
        let client = FakeHotSheetClient()
        let storePath = URL(fileURLWithPath: "/stores/a.hs2")

        init() throws {
            base = try TestSupport.makeTempDirectory()
            root = base.appendingPathComponent("Drafts")
            store = ReviewDraftStore(root: root, now: { Date(timeIntervalSince1970: 1000) })
            client.numbered = true
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        /// Adds captures (an image, a video, another image, …) to the current draft and one rect
        /// annotation on each.
        @discardableResult
        func draft(captures: Int = 3) throws -> ReviewDraft {
            var draft: ReviewDraft?
            for index in 1 ... captures {
                let kind: MediaKind = index == 2 ? .video : .image
                let file = base.appendingPathComponent("raw-\(index).\(kind == .image ? "png" : "mov")")
                try Data("bytes \(index)".utf8).write(to: file)
                draft = try store.add(DraftCapture(
                    fileURL: file, kind: kind, pixelWidth: 200, pixelHeight: 100,
                    durationMs: kind == .video ? 3000 : nil, capturedAt: Date(timeIntervalSince1970: 2000),
                    context: CaptureContext(appName: "Safari")
                )).draft
            }
            let directory = try #require(draft).directory
            return try store.update(directory) { bundle in
                bundle.annotations = bundle.media.map {
                    Annotation(id: "a-\($0.id)", mediaId: $0.id, shape: .rect(NormRect(x: 0, y: 0, width: 100, height: 100)), note: "n")
                }
            }
        }

        func submitter(_ path: URL? = nil) -> DraftSubmitter {
            DraftSubmitter(store: store, client: client, storePath: path ?? storePath, now: { Date(timeIntervalSince1970: 5000) })
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    @Test func filesAMultiCaptureDraftThenDeletesItAndTheNextCaptureStartsANewReview() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft()
        var steps: [SubmitStep] = []
        let result = try fixture.submitter().submit(draft.directory, title: "  Checkout polish \n", summary: "Overall notes") {
            steps.append($0)
        }
        #expect(steps == [.creatingTicket, .attachingMedia])
        #expect(result == SubmittedReview(
            ticket: CreatedTicket(slug: "HS-TEST01"), title: "Checkout polish", mediaCount: 3, annotationCount: 3,
            storePath: "/stores/a.hs2", submittedAt: Date(timeIntervalSince1970: 5000), draftRemoved: true
        ))
        #expect(fixture.client.created.map(\.title) == ["UX review: Checkout polish"])
        #expect(fixture.client.created.first?.details.contains("Overall notes") == true)
        let batch = try #require(fixture.client.attached.first)
        #expect(batch.files.map(\.lastPathComponent) == ["capture-1.png", "capture-2.mov", "capture-3.png", "review.json"])
        #expect(!fixture.exists(draft.directory))
        #expect(try fixture.store.current() == nil)

        try fixture.draft(captures: 1)
        let next = try #require(try fixture.store.current())
        #expect(next.directory != draft.directory)
        #expect(next.bundle.media.map(\.filename) == ["capture-1.png"])
    }

    @Test func filingAnOlderDraftKeepsTheCurrentOne() throws {
        let fixture = try Fixture()
        let old = try fixture.draft(captures: 1)
        try fixture.store.startNew()
        let current = try fixture.draft(captures: 1)
        _ = try fixture.submitter().submit(old.directory)
        #expect(!fixture.exists(old.directory))
        #expect(try fixture.store.current()?.directory == current.directory)
    }

    @Test func attachFailureKeepsTheDraftAndTheRetryReusesTheTicket() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 2)
        fixture.client.attachErrors = [
            HotSheetError.commandFailed(command: "attach", exitCode: 1, stderr: "locked"),
            HotSheetError.commandFailed(command: "attach", exitCode: 1, stderr: "still locked"),
        ]
        #expect(throws: SubmissionFailure(
            message: "HS-TEST01 was created, but attaching the media failed: hotsheet-cli attach failed (exit 1): locked",
            createdTicket: "HS-TEST01"
        )) { try fixture.submitter().submit(draft.directory) }
        #expect(fixture.exists(draft.directory))
        #expect(fixture.store.isCurrent(draft.directory))
        let pending = try #require(fixture.store.pendingSubmission(in: draft.directory))
        #expect(pending == PendingSubmission(
            storePath: "/stores/a.hs2",
            ticket: CreatedTicket(slug: "HS-TEST01"),
            createdAt: Date(timeIntervalSince1970: 5000)
        ))

        // Second failure: still one ticket, the record unchanged.
        var steps: [SubmitStep] = []
        #expect(throws: SubmissionFailure.self) { try fixture.submitter().submit(draft.directory) { steps.append($0) } }
        #expect(steps == [.attachingMedia])
        #expect(fixture.client.created.count == 1)
        #expect(fixture.store.pendingSubmission(in: draft.directory) == pending)

        let result = try fixture.submitter().submit(draft.directory)
        #expect(result.ticket.slug == "HS-TEST01")
        #expect(fixture.client.created.count == 1)
        #expect(fixture.client.attached.map(\.slug) == ["HS-TEST01"])
        #expect(!fixture.exists(draft.directory))
    }

    @Test func aPendingTicketInAnotherStoreIsNotReused() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 1)
        fixture.client.attachErrors = [HotSheetError.cliNotFound]
        #expect(throws: SubmissionFailure.self) { try fixture.submitter().submit(draft.directory) }
        let result = try fixture.submitter(URL(fileURLWithPath: "/stores/b.hs2")).submit(draft.directory)
        #expect(result.ticket.slug == "HS-TEST02")
        #expect(result.storePath == "/stores/b.hs2")
        #expect(fixture.client.created.count == 2)
    }

    @Test func createFailureKeepsTheDraftWithNoPendingRecord() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 2)
        fixture.client.createError = HotSheetError.commandFailed(command: "new", exitCode: 2, stderr: "no store")
        #expect(throws: SubmissionFailure(message: "hotsheet-cli new failed (exit 2): no store")) {
            try fixture.submitter().submit(draft.directory, title: "Kept title")
        }
        #expect(fixture.exists(draft.directory))
        #expect(fixture.store.pendingSubmission(in: draft.directory) == nil)
        // The fields were saved before filing, so nothing typed is lost.
        #expect(try fixture.store.load(draft.directory).bundle.title == "Kept title")
        fixture.client.createError = nil
        #expect(try fixture.submitter().submit(draft.directory).ticket.slug == "HS-TEST01")
    }

    @Test func missingMediaAndVanishedDraftsFailWithoutCreatingAnything() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 2)
        try FileManager.default.removeItem(at: draft.directory.appendingPathComponent("capture-2.mov"))
        #expect(throws: SubmissionFailure(message: "capture-2.mov is missing from the review.")) {
            try fixture.submitter().submit(draft.directory)
        }
        try FileManager.default.removeItem(at: draft.directory)
        #expect(throws: SubmissionFailure.self) { try fixture.submitter().submit(draft.directory) }
        #expect(fixture.client.created.isEmpty)
    }

    @Test func invalidBundleFailsWithItsIssues() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 1)
        try fixture.store.update(draft.directory) { $0.annotations[0].mediaId = "gone" }
        #expect(throws: SubmissionFailure(message: "The review has problems to fix first.")) {
            try fixture.submitter().submit(draft.directory)
        }
    }

    // MARK: Store operations

    @Test func removingACaptureDropsItsFileAnnotationsAndOriginal() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 3)
        let originals = draft.directory.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try Data("orig".utf8).write(to: originals.appendingPathComponent("capture-1.png"))
        try OriginalsIndex(
            crops: [
                "capture-1.png": PixelRect(x: 0, y: 0, width: 10, height: 10),
                "capture-3.png": PixelRect(x: 0, y: 0, width: 5, height: 5),
            ]
        ).save(to: originals)

        let after = try fixture.store.removeMedia("m1", from: draft.directory)
        #expect(after.bundle.media.map(\.id) == ["m2", "m3"])
        #expect(after.bundle.annotations.map(\.mediaId) == ["m2", "m3"])
        #expect(try fixture.store.load(draft.directory) == after)
        #expect(!fixture.exists(draft.directory.appendingPathComponent("capture-1.png")))
        #expect(!fixture.exists(originals.appendingPathComponent("capture-1.png")))
        #expect(OriginalsIndex.load(from: originals).crops.keys.sorted() == ["capture-3.png"])

        #expect(throws: ReviewDraftError.unknownMedia("m1")) { try fixture.store.removeMedia("m1", from: draft.directory) }
        #expect(try fixture.store.load(draft.directory) == after)

        // Empty, then refilled: the next capture continues the numbering.
        try fixture.store.removeMedia("m2", from: draft.directory)
        let empty = try fixture.store.removeMedia("m3", from: draft.directory)
        #expect(empty.bundle.media.isEmpty && empty.bundle.annotations.isEmpty)
        #expect(empty.bundle.validate() == [.noMedia])
        let refilled = try fixture.draft(captures: 1)
        #expect(refilled.directory == draft.directory)
        #expect(refilled.bundle.media.map(\.id) == ["m1"])
    }

    @Test func setDetailsKeepsCapturesAddedMeanwhile() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 1)
        try fixture.draft(captures: 1) // a capture lands in the same draft
        let saved = try fixture.store.setDetails(draft.directory, title: "New", summary: "Sum")
        #expect(saved.bundle.title == "New" && saved.bundle.summary == "Sum")
        #expect(saved.bundle.media.count == 2)
    }

    @Test func removeSubmittedRefusesAnythingButADraftDirectory() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 1)
        for bad in [
            fixture.root,
            fixture.base,
            fixture.root.appendingPathComponent("current"),
            fixture.root.appendingPathComponent(".hidden"),
            draft.directory.appendingPathComponent("originals"),
            fixture.root.appendingPathComponent("x/../../outside"),
        ] {
            #expect(throws: ReviewDraftError.outsideDrafts(bad)) { try fixture.store.removeSubmitted(bad) }
        }
        #expect(fixture.exists(draft.directory))
        #expect(fixture.store.isCurrent(draft.directory))
        // Removing twice is harmless.
        try fixture.store.removeSubmitted(draft.directory)
        try fixture.store.removeSubmitted(draft.directory)
        #expect(!fixture.store.isCurrent(draft.directory))
    }

    @Test func unreadablePendingRecordIsIgnored() throws {
        let fixture = try Fixture()
        let draft = try fixture.draft(captures: 1)
        try Data("{".utf8).write(to: draft.directory.appendingPathComponent(ReviewDraftStore.pendingSubmissionFilename))
        #expect(fixture.store.pendingSubmission(in: draft.directory) == nil)
        #expect(try fixture.submitter().submit(draft.directory).ticket.slug == "HS-TEST01")
    }
}
