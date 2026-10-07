import Foundation
import Testing
@testable import UXReviewKit

/// Listing every draft and discarding one (docs/07 §7.9): the states no drafts → one current →
/// several (current and ended) → discarded, walked through realistic and adversarial sequences
/// (discard current vs. not, discard twice, discard then capture, unreadable drafts, symlinks
/// and paths outside the drafts folder, a Trash that refuses).
struct DraftListingTests {
    final class Fixture {
        let base: URL
        let root: URL
        let trashFolder: URL
        let store: ReviewDraftStore
        private var counter = 0

        init(trash: DraftTrash? = nil) throws {
            base = try TestSupport.makeTempDirectory()
            root = base.appendingPathComponent("Drafts")
            trashFolder = base.appendingPathComponent("Trash")
            let ids = Counter()
            store = ReviewDraftStore(
                root: root,
                now: { Date(timeIntervalSince1970: 1000) },
                makeID: { "draft-\(ids.next())" },
                trash: trash ?? .folder(trashFolder)
            )
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        /// Adds `count` image captures to the current draft (or to `directory`).
        @discardableResult
        func capture(_ count: Int = 1, to directory: URL? = nil) throws -> ReviewDraft {
            var draft: ReviewDraft?
            for _ in 0 ..< count {
                counter += 1
                let file = base.appendingPathComponent("raw-\(counter).png")
                try Data("bytes".utf8).write(to: file)
                draft = try store.add(DraftCapture(
                    fileURL: file, kind: .image, pixelWidth: 10, pixelHeight: 10,
                    capturedAt: Date(timeIntervalSince1970: 2000), context: CaptureContext(appName: "Safari")
                ), to: directory).draft
            }
            return try #require(draft)
        }

        /// Pins review.json's modification date so the listing order is deterministic.
        func touch(_ draft: ReviewDraft, _ seconds: TimeInterval) throws {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: seconds)],
                ofItemAtPath: draft.bundleURL.path
            )
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    // MARK: Listing

    @Test func aMissingOrEmptyRootListsNothing() throws {
        let fixture = try Fixture()
        #expect(try fixture.store.listDrafts().isEmpty)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        #expect(try fixture.store.listDrafts().isEmpty)
        try fixture.store.startNew()
        #expect(try fixture.store.listDrafts().isEmpty)
    }

    @Test func listsEveryDraftNewestFirstWithItsDetails() throws {
        let fixture = try Fixture()
        let first = try fixture.capture(2)
        try fixture.store.update(first.directory) { bundle in
            bundle.title = "Checkout polish"
            bundle.annotations = [Annotation(id: "a1", mediaId: "m1", shape: .insertion(NormPoint(x: 1, y: 1)), note: "n")]
        }
        try fixture.store.startNew()
        let second = try fixture.capture(1)
        try fixture.touch(first, 5000)
        try fixture.touch(second, 6000)

        let drafts = try fixture.store.listDrafts()
        #expect(drafts.map(\.name) == ["draft-2", "draft-1"])
        #expect(drafts[0] == DraftSummary(
            directory: fixture.root.appendingPathComponent("draft-2", isDirectory: true),
            title: "Safari review", captureCount: 1, annotationCount: 0,
            createdAt: Date(timeIntervalSince1970: 1000), modifiedAt: Date(timeIntervalSince1970: 6000), isCurrent: true
        ))
        #expect(drafts[1].title == "Checkout polish")
        #expect((drafts[1].captureCount, drafts[1].annotationCount, drafts[1].isCurrent) == (2, 1, false))

        // Editing the older draft moves it to the top; which one is current doesn't change.
        try fixture.touch(first, 7000)
        #expect(try fixture.store.listDrafts().map { "\($0.name):\($0.isCurrent)" } == ["draft-1:false", "draft-2:true"])
    }

    @Test func equalDatesSortByNameNewestFirst() throws {
        let fixture = try Fixture()
        let first = try fixture.capture()
        try fixture.store.startNew()
        let second = try fixture.capture()
        try fixture.touch(first, 5000)
        try fixture.touch(second, 5000)
        #expect(try fixture.store.listDrafts().map(\.name) == ["draft-2", "draft-1"])
    }

    @Test func unreadableDraftsAreListedWithAnIssueAndClutterIsSkipped() throws {
        let fixture = try Fixture()
        let good = try fixture.capture()
        try fixture.touch(good, Date().timeIntervalSince1970 + 86400) // newer than the folders made below
        let fileManager = FileManager.default
        let corrupt = fixture.root.appendingPathComponent("corrupt")
        try fileManager.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: corrupt.appendingPathComponent("review.json"))
        let empty = fixture.root.appendingPathComponent("empty")
        try fileManager.createDirectory(at: empty, withIntermediateDirectories: true)
        // Clutter: hidden folders and files, a stray file, a link to a folder outside the root.
        try fileManager.createDirectory(at: fixture.root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data().write(to: fixture.root.appendingPathComponent(".DS_Store"))
        try Data().write(to: fixture.root.appendingPathComponent("notes.txt"))
        let outside = fixture.base.appendingPathComponent("outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: fixture.root.appendingPathComponent("link"), withDestinationURL: outside)

        let drafts = try fixture.store.listDrafts()
        #expect(Set(drafts.map(\.name)) == ["draft-1", "corrupt", "empty"])
        #expect(drafts.first?.name == "draft-1")
        let byName = Dictionary(uniqueKeysWithValues: drafts.map { ($0.name, $0) })
        #expect(byName["corrupt"]?.issue == "review.json can't be read.")
        #expect(byName["corrupt"]?.title == "corrupt")
        #expect(byName["empty"]?.issue == "review.json is missing.")
        #expect(byName["empty"]?.isReadable == false)
        #expect(byName["draft-1"]?.isReadable == true)
    }

    @Test func aCorruptCurrentDraftIsStillMarkedCurrent() throws {
        let fixture = try Fixture()
        let draft = try fixture.capture()
        try Data("garbage".utf8).write(to: draft.bundleURL)
        let listed = try #require(try fixture.store.listDrafts().first)
        #expect(listed.isCurrent && !listed.isReadable)
    }

    @Test func aPendingSubmissionNamesItsTicket() throws {
        let fixture = try Fixture()
        let draft = try fixture.capture()
        try fixture.store.savePendingSubmission(
            PendingSubmission(storePath: "/s.hs2", ticket: CreatedTicket(slug: "HS-ABC123"), createdAt: Date()),
            in: draft.directory
        )
        #expect(try fixture.store.listDrafts().first?.pendingTicket == "HS-ABC123")
        try Data("broken".utf8).write(to: draft.directory.appendingPathComponent("submission.json"))
        #expect(try fixture.store.listDrafts().first?.pendingTicket == nil)
    }

    @Test func summaryOfOneDraftMatchesTheListing() throws {
        let fixture = try Fixture()
        let old = try fixture.capture(2)
        try fixture.store.startNew()
        let current = try fixture.capture()
        let listed = try fixture.store.listDrafts()
        #expect(try fixture.store.summary(of: old.directory) == listed.first { $0.name == "draft-1" })
        #expect(try fixture.store.summary(of: current.directory).isCurrent)
        #expect(throws: ReviewDraftError.outsideDrafts(fixture.root)) { try fixture.store.summary(of: fixture.root) }
        try fixture.store.discard(old.directory)
        #expect(throws: ReviewDraftError.noSuchDraft(old.directory)) { try fixture.store.summary(of: old.directory) }
    }

    // MARK: Discarding

    @Test func discardingTheCurrentDraftEndsItAndTheNextCaptureStartsANewOne() throws {
        let fixture = try Fixture()
        let draft = try fixture.capture(2)
        let result = try fixture.store.discard(draft.directory)
        #expect(result.wasCurrent)
        #expect(result.trashedTo == fixture.trashFolder.appendingPathComponent("draft-1", isDirectory: true))
        #expect(!fixture.exists(draft.directory))
        #expect(fixture.exists(fixture.trashFolder.appendingPathComponent("draft-1/capture-2.png")))
        #expect(!fixture.exists(fixture.root.appendingPathComponent("current")))
        #expect(try fixture.store.current() == nil)
        #expect(try fixture.store.listDrafts().isEmpty)

        let next = try fixture.capture()
        #expect(next.directory.lastPathComponent == "draft-2")
        #expect(next.bundle.media.map(\.filename) == ["capture-1.png"])
        #expect(try fixture.store.listDrafts().map(\.name) == ["draft-2"])
    }

    @Test func discardingAnOlderDraftKeepsTheCurrentOne() throws {
        let fixture = try Fixture()
        let old = try fixture.capture()
        try fixture.store.startNew()
        let current = try fixture.capture()
        let result = try fixture.store.discard(old.directory)
        #expect(!result.wasCurrent)
        #expect(try fixture.store.current()?.directory == current.directory)
        #expect(try fixture.store.listDrafts().map(\.name) == ["draft-2"])
        // The next capture still goes to the current draft.
        #expect(try fixture.capture().directory == current.directory)
    }

    @Test func discardingTwiceFailsTheSecondTimeAndChangesNothing() throws {
        let fixture = try Fixture()
        let old = try fixture.capture()
        try fixture.store.startNew()
        let current = try fixture.capture()
        try fixture.store.discard(old.directory)
        #expect(throws: ReviewDraftError.noSuchDraft(old.directory)) { try fixture.store.discard(old.directory) }
        #expect(try fixture.store.current()?.directory == current.directory)
        let trashed = try FileManager.default.contentsOfDirectory(atPath: fixture.trashFolder.path)
        #expect(trashed == ["draft-1"])
    }

    @Test func aDraftWithTheSameNameAsOneInTheTrashGetsAFreshName() throws {
        let fixture = try Fixture()
        let draft = try fixture.capture()
        try FileManager.default.createDirectory(
            at: fixture.trashFolder.appendingPathComponent("draft-1"),
            withIntermediateDirectories: true
        )
        let result = try fixture.store.discard(draft.directory)
        #expect(result.trashedTo?.lastPathComponent == "draft-1 2")
    }

    @Test func unreadableDraftsCanBeDiscarded() throws {
        let fixture = try Fixture()
        let draft = try fixture.capture()
        try Data("garbage".utf8).write(to: draft.bundleURL)
        let empty = fixture.root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(try fixture.store.discard(draft.directory).wasCurrent)
        #expect(!fixture.exists(fixture.root.appendingPathComponent("current")))
        #expect(try !fixture.store.discard(empty).wasCurrent)
        #expect(try fixture.store.listDrafts().isEmpty)
    }

    @Test func refusesAnythingButADraftFolderInsideTheRoot() throws {
        let fixture = try Fixture()
        let draft = try fixture.capture()
        let fileManager = FileManager.default
        let outside = fixture.base.appendingPathComponent("outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = fixture.root.appendingPathComponent("link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)
        let innerLink = fixture.root.appendingPathComponent("alias")
        try fileManager.createSymbolicLink(at: innerLink, withDestinationURL: draft.directory)
        try fileManager.createDirectory(at: fixture.root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        for bad in [
            fixture.root,
            fixture.base,
            outside,
            link,
            innerLink,
            fixture.root.appendingPathComponent("current"),
            fixture.root.appendingPathComponent(".hidden"),
            fixture.root.appendingPathComponent(".."),
            draft.directory.appendingPathComponent("originals"),
            fixture.root.appendingPathComponent("x/../../outside"),
            URL(fileURLWithPath: "/"),
        ] {
            #expect(throws: ReviewDraftError.outsideDrafts(bad)) { try fixture.store.discard(bad) }
        }
        #expect(fixture.exists(outside) && fixture.exists(draft.directory) && fixture.exists(link))
        #expect(fixture.store.isCurrent(draft.directory))
        #expect(!fixture.exists(fixture.trashFolder))
    }

    @Test func aPlainFileInsideTheRootIsNotADraft() throws {
        let fixture = try Fixture()
        try fixture.capture()
        let file = fixture.root.appendingPathComponent("notes.txt")
        try Data().write(to: file)
        #expect(throws: ReviewDraftError.noSuchDraft(file)) { try fixture.store.discard(file) }
        #expect(fixture.exists(file))
    }

    @Test func aTrashThatRefusesKeepsTheDraftAndItsPointer() throws {
        let base = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        // The "trash folder" is a file, so moving into it fails.
        let blocker = base.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let fixture = try Fixture(trash: .folder(blocker.appendingPathComponent("Trash")))
        let draft = try fixture.capture()
        #expect(throws: ReviewDraftError.self) { try fixture.store.discard(draft.directory) }
        #expect(fixture.exists(draft.bundleURL))
        #expect(fixture.store.isCurrent(draft.directory))
    }

    @Test func aRelativeOrUnstandardizedPathToADraftWorks() throws {
        let fixture = try Fixture()
        let draft = try fixture.capture()
        let messy = fixture.root.appendingPathComponent("sub/../draft-1/")
        #expect(try fixture.store.discard(messy).wasCurrent)
        #expect(!fixture.exists(draft.directory))
    }

    @Test func removeSubmittedClearsTheCurrentPointerEvenWhenTheDraftIsCorrupt() throws {
        let fixture = try Fixture()
        let draft = try fixture.capture()
        try Data("garbage".utf8).write(to: draft.bundleURL)
        try fixture.store.removeSubmitted(draft.directory)
        #expect(!fixture.exists(fixture.root.appendingPathComponent("current")))
    }

    // MARK: Trash selection and command parsing

    @Test func trashComesFromTheEnvironment() {
        #expect(DraftTrash.from(environment: [:]) == .system)
        #expect(DraftTrash.from(environment: ["UXREVIEW_TRASH_DIR": ""]) == .system)
        #expect(DraftTrash.from(environment: ["UXREVIEW_TRASH_DIR": "/t"]) == .folder(URL(fileURLWithPath: "/t", isDirectory: true)))
    }

    @Test func parsesDraftsCommands() throws {
        let drafts = URL(fileURLWithPath: "/d", isDirectory: true)
        #expect(try DraftsCommand.parse(["--status"]) == nil)
        #expect(try DraftsCommand.parse(["--drafts"]) == .list(draftsDirectory: nil))
        #expect(try DraftsCommand.parse(["--drafts", "--drafts-dir", "/d"]) == .list(draftsDirectory: drafts))
        let discard = try #require(try DraftsCommand.parse(["--discard-draft", "draft-1", "--drafts-dir", "/d"]))
        #expect(discard == .discard(draft: "draft-1", draftsDirectory: drafts))
        #expect(discard.draftsDirectory == drafts)
        #expect(discard.target(in: drafts)?.path == "/d/draft-1")
        let path = try #require(try DraftsCommand.parse(["--discard-draft", "/elsewhere/x"]))
        #expect(path.target(in: drafts)?.path == "/elsewhere/x")
        #expect(DraftsCommand.list(draftsDirectory: nil).target(in: drafts) == nil)
        #expect(throws: CommandLineError.missingValue("--discard-draft")) { try DraftsCommand.parse(["--discard-draft"]) }
        #expect(throws: CommandLineError.missingValue("--discard-draft")) { try DraftsCommand.parse(["--discard-draft", "--drafts"]) }
        #expect(throws: CommandLineError.missingValue("--drafts-dir")) { try DraftsCommand.parse(["--drafts", "--drafts-dir"]) }
    }
}
