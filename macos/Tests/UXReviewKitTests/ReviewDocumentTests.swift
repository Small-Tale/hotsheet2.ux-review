import Foundation
import Testing
@testable import UXReviewKit

/// Reviews as `.uxreview` documents (HS2-BKWZ5N, HS2-0D87NR; docs/07 §7.9): untitled packages
/// in the drafts root, saving one anywhere, copies, the current pointer following it, removal
/// after filing, and Open Recent.
struct ReviewDocumentTests {
    final class Fixture {
        let base: URL
        let root: URL
        let elsewhere: URL
        let trashFolder: URL
        let store: ReviewDraftStore

        init() throws {
            base = try TestSupport.makeTempDirectory()
            root = base.appendingPathComponent("Drafts", isDirectory: true)
            elsewhere = base.appendingPathComponent("Documents", isDirectory: true)
            trashFolder = base.appendingPathComponent("Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let ids = IDs()
            store = ReviewDraftStore(root: root, makeID: { ids.next() }, trash: .folder(trashFolder))
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        /// Draft ids in order, then random ones.
        final class IDs: @unchecked Sendable {
            private var ids = ["20261009-010000-AAAAAA", "20261009-010000-BBBBBB", "20261009-010000-CCCCCC"]
            func next() -> String { ids.isEmpty ? ReviewDraftStore.makeDraftID() : ids.removeFirst() }
        }

        func capture(_ name: String) throws -> DraftCapture {
            let file = base.appendingPathComponent(name)
            try Data("png \(name)".utf8).write(to: file)
            return DraftCapture(
                fileURL: file,
                kind: .image,
                pixelWidth: 10,
                pixelHeight: 10,
                capturedAt: Date(),
                context: CaptureContext(appName: "Safari")
            )
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func current() throws -> URL? { try store.current()?.directory.standardizedFileURL.resolvingSymlinksInPath() }
        func resolved(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    }

    @Test func newReviewsAreUntitledPackagesInTheDraftsFolder() throws {
        let fixture = try Fixture()
        let draft = try fixture.store.add(fixture.capture("a.png")).draft
        #expect(draft.directory.lastPathComponent == "20261009-010000-AAAAAA.uxreview")
        #expect(draft.bundle.id == "20261009-010000-AAAAAA")
        #expect(fixture.store.isUntitled(draft.directory))
        #expect(
            try String(contentsOf: fixture.root.appendingPathComponent("current"), encoding: .utf8) ==
                "20261009-010000-AAAAAA.uxreview"
        )
    }

    @Test func savingMovesTheReviewAndCapturesFollowIt() throws {
        let fixture = try Fixture()
        let draft = try fixture.store.add(fixture.capture("a.png")).draft
        let saved = try fixture.store.save(draft.directory, to: fixture.elsewhere.appendingPathComponent("Checkout"))
        #expect(saved.directory.lastPathComponent == "Checkout.uxreview", "the extension is added")
        #expect(!fixture.exists(draft.directory) && fixture.exists(saved.directory.appendingPathComponent("capture-1.png")))
        #expect(!fixture.store.isUntitled(saved.directory))
        // The current pointer names it by absolute path, and the next capture goes into it.
        #expect(try fixture.current() == fixture.resolved(saved.directory))
        let next = try fixture.store.add(fixture.capture("b.png")).draft
        #expect(fixture.resolved(next.directory) == fixture.resolved(saved.directory))
        #expect(next.bundle.media.map(\.filename) == ["capture-1.png", "capture-2.png"])
        // Saving to where it already is changes nothing.
        #expect(try fixture.store.save(saved.directory, to: saved.directory).directory == saved.directory)
    }

    @Test func savingANonCurrentReviewLeavesTheCurrentOneAlone() throws {
        let fixture = try Fixture()
        let old = try fixture.store.add(fixture.capture("a.png")).draft
        let current = try fixture.store.createEmptyDraft()
        _ = try fixture.store.save(old.directory, to: fixture.elsewhere.appendingPathComponent("Old.uxreview"))
        #expect(try fixture.current() == fixture.resolved(current.directory))
    }

    @Test func savingOverSomethingAsksFirstThenTrashesIt() throws {
        let fixture = try Fixture()
        let draft = try fixture.store.add(fixture.capture("a.png")).draft
        let target = fixture.elsewhere.appendingPathComponent("Taken.uxreview")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("marker"))
        #expect(throws: ReviewDraftError.self) {
            try fixture.store.save(draft.directory, to: target)
        }
        #expect(fixture.exists(draft.directory), "nothing moved")
        let saved = try fixture.store.save(draft.directory, to: target, replacing: true)
        #expect(fixture.exists(saved.directory.appendingPathComponent("review.json")))
        #expect(fixture.exists(fixture.trashFolder.appendingPathComponent("Taken.uxreview/marker")), "the replaced item is in the Trash")
    }

    @Test func aPendingSubmissionMovesWithTheReviewButNotIntoCopies() throws {
        let fixture = try Fixture()
        let draft = try fixture.store.add(fixture.capture("a.png")).draft
        let pending = PendingSubmission(storePath: "/s.hs2", ticket: CreatedTicket(slug: "HS-1", file: nil), createdAt: Date())
        try fixture.store.savePendingSubmission(pending, in: draft.directory)
        try FileManager.default.createDirectory(
            at: draft.directory.appendingPathComponent(SubmissionStaging.folderName), withIntermediateDirectories: true
        )
        let saved = try fixture.store.save(draft.directory, to: fixture.elsewhere.appendingPathComponent("R"))
        #expect(fixture.store.pendingSubmission(in: saved.directory)?.ticket.slug == "HS-1")

        let copy = try fixture.store.saveCopy(saved.directory, to: fixture.elsewhere.appendingPathComponent("Copy"))
        #expect(fixture.store.pendingSubmission(in: copy.directory) == nil)
        #expect(!fixture.exists(copy.directory.appendingPathComponent(SubmissionStaging.folderName)))
        let duplicate = try fixture.store.duplicate(saved.directory)
        #expect(fixture.store.pendingSubmission(in: duplicate.directory) == nil)
    }

    @Test func saveAsWritesACopyAndLeavesTheOriginal() throws {
        let fixture = try Fixture()
        let draft = try fixture.store.add(fixture.capture("a.png")).draft
        try fixture.store.update(draft.directory) { $0.title = "Original" }
        let copy = try fixture.store.saveCopy(draft.directory, to: fixture.elsewhere.appendingPathComponent("Copy.uxreview"))
        #expect(copy.bundle.title == "Original" && copy.bundle.media.map(\.filename) == ["capture-1.png"])
        #expect(copy.bundle.id != draft.bundle.id, "a fresh review")
        #expect(fixture.exists(draft.directory), "the original stays")
        #expect(try fixture.current() == fixture.resolved(draft.directory), "Save As doesn't change which review captures go to")
        try fixture.store.update(copy.directory) { $0.title = "Changed copy" }
        #expect(try fixture.store.load(draft.directory).bundle.title == "Original")
        #expect(throws: ReviewDraftError.self) {
            try fixture.store.saveCopy(draft.directory, to: copy.directory)
        }
    }

    @Test func duplicateMakesAnUntitledCopy() throws {
        let fixture = try Fixture()
        let draft = try fixture.store.add(fixture.capture("a.png")).draft
        try fixture.store.update(draft.directory) { $0.title = "Checkout" }
        let duplicate = try fixture.store.duplicate(draft.directory)
        #expect(fixture.store.isUntitled(duplicate.directory) && duplicate.directory.pathExtension == "uxreview")
        #expect(duplicate.bundle.title == "Checkout copy")
        #expect(duplicate.bundle.id == duplicate.directory.deletingPathExtension().lastPathComponent)
        #expect(duplicate.bundle.id != draft.bundle.id)
        #expect(try fixture.current() == fixture.resolved(draft.directory))
        #expect(try fixture.store.listDrafts().count == 2)
    }

    @Test func openReadsAReviewAnywhereAndMakeCurrentPointsAtIt() throws {
        let fixture = try Fixture()
        let draft = try fixture.store.add(fixture.capture("a.png")).draft
        let saved = try fixture.store.save(draft.directory, to: fixture.elsewhere.appendingPathComponent("R"))
        _ = try fixture.store.createEmptyDraft()
        #expect(try fixture.store.open(saved.directory).bundle.media.count == 1)
        try fixture.store.makeCurrent(saved.directory)
        #expect(try fixture.current() == fixture.resolved(saved.directory))

        let notAReview = fixture.elsewhere.appendingPathComponent("Empty.uxreview")
        try FileManager.default.createDirectory(at: notAReview, withIntermediateDirectories: true)
        #expect(throws: ReviewDraftError.self) { try fixture.store.open(notAReview) }
        #expect(throws: ReviewDraftError.self) { try fixture.store.makeCurrent(notAReview) }
        #expect(try fixture.current() == fixture.resolved(saved.directory), "a failed makeCurrent changes nothing")
    }

    @Test func filingASavedReviewTrashesItAndAnUntitledOneIsDeleted() throws {
        let fixture = try Fixture()
        let draft = try fixture.store.add(fixture.capture("a.png")).draft
        let saved = try fixture.store.save(draft.directory, to: fixture.elsewhere.appendingPathComponent("Filed"))
        try fixture.store.removeSubmitted(saved.directory)
        #expect(!fixture.exists(saved.directory))
        #expect(fixture.exists(fixture.trashFolder.appendingPathComponent("Filed.uxreview/capture-1.png")))
        #expect(try fixture.store.current() == nil, "the next capture starts a new review")

        let untitled = try fixture.store.add(fixture.capture("b.png")).draft
        try fixture.store.removeSubmitted(untitled.directory)
        #expect(!fixture.exists(untitled.directory))
        #expect(!fixture.exists(fixture.trashFolder.appendingPathComponent(untitled.directory.lastPathComponent)))
    }

    @Test func discardingASavedReviewMovesItToTheTrash() throws {
        let fixture = try Fixture()
        let draft = try fixture.store.add(fixture.capture("a.png")).draft
        let saved = try fixture.store.save(draft.directory, to: fixture.elsewhere.appendingPathComponent("Gone"))
        let result = try fixture.store.discard(saved.directory)
        #expect(result.wasCurrent && !fixture.exists(saved.directory))
        #expect(result.trashedTo?.lastPathComponent == "Gone.uxreview")
    }

    @Test func onlyRealReviewPackagesOutsideTheDraftsFolderAreAccepted() throws {
        let fixture = try Fixture()
        let plain = fixture.elsewhere.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: plain.appendingPathComponent("review.json"))
        #expect(throws: ReviewDraftError.outsideDrafts(plain)) { try fixture.store.discard(plain) }
        #expect(throws: ReviewDraftError.outsideDrafts(plain)) { try fixture.store.removeSubmitted(plain) }

        let empty = fixture.elsewhere.appendingPathComponent("Empty.uxreview", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: ReviewDraftError.outsideDrafts(empty)) { try fixture.store.discard(empty) }

        let draft = try fixture.store.add(fixture.capture("a.png")).draft
        let saved = try fixture.store.save(draft.directory, to: fixture.elsewhere.appendingPathComponent("Real"))
        let link = fixture.elsewhere.appendingPathComponent("Link.uxreview")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: saved.directory)
        #expect(throws: ReviewDraftError.outsideDrafts(link)) { try fixture.store.discard(link) }
        #expect(fixture.exists(saved.directory))
    }

    @Test func aMalformedPointerIsIgnored() throws {
        let fixture = try Fixture()
        let pointer = fixture.root.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        for value in ["/etc", "/tmp/not-a-review.uxreview", "a/b", ""] {
            try Data(value.utf8).write(to: pointer)
            #expect(try fixture.store.current() == nil, "\(value)")
        }
    }

    /// A realistic sequence across the operations, checking the pointer at each step.
    @Test func aDocumentLifeCycle() throws {
        let fixture = try Fixture()
        let first = try fixture.store.add(fixture.capture("1.png")).draft
        let saved = try fixture.store.save(first.directory, to: fixture.elsewhere.appendingPathComponent("Life"))
        _ = try fixture.store.add(fixture.capture("2.png"))
        let copy = try fixture.store.saveCopy(saved.directory, to: fixture.elsewhere.appendingPathComponent("Life 2"))
        try fixture.store.makeCurrent(copy.directory)
        _ = try fixture.store.add(fixture.capture("3.png"))
        #expect(try fixture.store.load(copy.directory).bundle.media.count == 3)
        #expect(try fixture.store.load(saved.directory).bundle.media.count == 2)
        let duplicate = try fixture.store.duplicate(copy.directory)
        try fixture.store.removeSubmitted(copy.directory)
        #expect(try fixture.store.current() == nil)
        let next = try fixture.store.add(fixture.capture("4.png")).draft
        #expect(fixture.store.isUntitled(next.directory) && next.directory != duplicate.directory)
        #expect(Set(try fixture.store.listDrafts().map(\.directory.lastPathComponent)).count == 2)
    }
}

struct RecentReviewsTests {
    @Test func notesMostRecentFirstDedupedAndCapped() {
        var recent = RecentReviews()
        for index in 1 ... 12 {
            recent.note("/r/\(index).uxreview")
        }
        recent.note("/r/5.uxreview/")
        recent.note(" ")
        #expect(recent.paths.count == RecentReviews.limit)
        #expect(recent.paths.first == "/r/5.uxreview")
        #expect(!recent.paths.contains("/r/1.uxreview") && !recent.paths.contains("/r/2.uxreview"))
        recent.move("/r/12.uxreview", to: "/saved/Twelve.uxreview")
        #expect(recent.paths[1] == "/saved/Twelve.uxreview", "a moved review keeps its place")
        recent.move("/unknown.uxreview", to: "/saved/New.uxreview")
        #expect(recent.paths.first == "/saved/New.uxreview")
        recent.remove("/saved/New.uxreview")
        #expect(recent.paths.first == "/r/5.uxreview")
        recent.clear()
        #expect(recent.paths.isEmpty)
    }

    @Test func persistsAndToleratesBadData() throws {
        let store = MemoryStore()
        #expect(RecentReviews.load(from: store) == RecentReviews())
        let recent = RecentReviews(paths: ["/a.uxreview", "/b.uxreview"])
        try recent.save(to: store)
        #expect(RecentReviews.load(from: store) == recent)
        store.set(Data("nope".utf8), forKey: RecentReviews.key)
        #expect(RecentReviews.load(from: store) == RecentReviews())
    }

    @Test func entriesAreTitledSkipMissingReviewsAndTellRepeatsApart() throws {
        let fixture = try ReviewDocumentTests.Fixture()
        let one = try fixture.store.add(fixture.capture("a.png")).draft
        try fixture.store.update(one.directory) { $0.title = "Checkout" }
        let saved = try fixture.store.save(one.directory, to: fixture.elsewhere.appendingPathComponent("Checkout"))
        let two = try fixture.store.createEmptyDraft()
        try fixture.store.update(two.directory) { $0.title = "Checkout" }
        let three = try fixture.store.createEmptyDraft()
        try fixture.store.update(three.directory) { $0.title = "Settings" }
        let recent = RecentReviews(paths: [three.directory.path, "/gone.uxreview", two.directory.path, saved.directory.path])
        let entries = recent.entries(store: fixture.store)
        #expect(entries.map(\.title) == ["Settings", "Checkout — Not saved", "Checkout — Documents"])
        #expect(entries.map(\.isUntitled) == [true, true, false])
    }
}

struct ReviewDocumentCommandTests {
    @Test func parsesEachCommand() throws {
        #expect(try ReviewDocumentCommand.parse(["--drafts"]) == nil)
        #expect(try ReviewDocumentCommand.parse(["--open-review", "/a/R.uxreview"]) == .open(review: "/a/R.uxreview", draftsDirectory: nil))
        #expect(
            try ReviewDocumentCommand.parse(["--save-review", "d", "--to", "/x/R", "--copy", "--drafts-dir", "/dd"])
                == .save(
                    review: "d",
                    destination: "/x/R",
                    copy: true,
                    replace: false,
                    draftsDirectory: URL(fileURLWithPath: "/dd", isDirectory: true)
                )
        )
        #expect(
            try ReviewDocumentCommand.parse(["--save-review", "d", "--to", "/x/R", "--replace"])
                == .save(review: "d", destination: "/x/R", copy: false, replace: true, draftsDirectory: nil)
        )
        #expect(try ReviewDocumentCommand.parse(["--duplicate-review", "d"]) == .duplicate(review: "d", draftsDirectory: nil))
        #expect(throws: CommandLineError.self) { try ReviewDocumentCommand.parse(["--save-review", "d"]) }
        #expect(throws: CommandLineError.self) { try ReviewDocumentCommand.parse(["--open-review"]) }
        #expect(throws: CommandLineError.self) { try ReviewDocumentCommand.parse(["--open-review", "a", "--duplicate-review", "b"]) }
    }

    @Test func namesResolveInTheDraftsFolderWithOrWithoutTheExtension() throws {
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("abc.uxreview"), withIntermediateDirectories: true)
        #expect(ReviewDocumentCommand.duplicate(review: "abc", draftsDirectory: nil).review(in: root).lastPathComponent == "abc.uxreview")
        #expect(
            ReviewDocumentCommand.duplicate(review: "abc.uxreview", draftsDirectory: nil).review(in: root)
                .lastPathComponent == "abc.uxreview"
        )
        #expect(ReviewDocumentCommand.open(review: "/x/Y.uxreview", draftsDirectory: nil).review(in: root).path == "/x/Y.uxreview")
    }
}
