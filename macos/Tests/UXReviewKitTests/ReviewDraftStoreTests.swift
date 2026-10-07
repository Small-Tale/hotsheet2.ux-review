import Foundation
import Testing
@testable import UXReviewKit

/// Walks the draft store's states (no draft → current draft → ended) through realistic and
/// adversarial sequences: repeated adds, start-new, stale or corrupt pointers, failed adds.
struct ReviewDraftStoreTests {
    final class IDQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var ids = ["draft-a", "draft-b", "draft-c", "draft-d"]

        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            return ids.removeFirst()
        }
    }

    final class Fixture {
        let root: URL
        let scratch: URL
        let store: ReviewDraftStore

        init() throws {
            let base = try TestSupport.makeTempDirectory()
            root = base.appendingPathComponent("Drafts")
            scratch = base.appendingPathComponent("scratch")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let ids = IDQueue()
            store = ReviewDraftStore(root: root, now: { Date(timeIntervalSince1970: 1000) }, makeID: { ids.next() })
        }

        deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        func capture(
            _ name: String = "shot.png",
            kind: MediaKind = .image,
            context: CaptureContext = CaptureContext(appName: "Safari")
        ) throws
            -> DraftCapture {
            let url = scratch.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return DraftCapture(
                fileURL: url, kind: kind, pixelWidth: 200, pixelHeight: 100,
                durationMs: kind == .video ? 1500 : nil, capturedAt: Date(timeIntervalSince1970: 2000), context: context
            )
        }

        func bundleOnDisk(_ id: String) throws -> ReviewBundle {
            let url = root.appendingPathComponent(id).appendingPathComponent("review.json")
            return try ReviewBundle.makeDecoder().decode(ReviewBundle.self, from: Data(contentsOf: url))
        }
    }

    @Test func noDraftUntilTheFirstCapture() throws {
        let fixture = try Fixture()
        #expect(try fixture.store.current() == nil)
        try fixture.store.startNew() // ending a draft that doesn't exist is fine
        #expect(try fixture.store.current() == nil)
    }

    @Test func firstCaptureCreatesADraftAndMovesTheFileIn() throws {
        let fixture = try Fixture()
        let capture = try fixture.capture()
        let (draft, media) = try fixture.store.add(capture)

        #expect(draft.directory.lastPathComponent == "draft-a")
        #expect(media == MediaItem(
            id: "m1", filename: "capture-1.png", kind: .image, pixelWidth: 200, pixelHeight: 100,
            capturedAt: Date(timeIntervalSince1970: 2000), context: CaptureContext(appName: "Safari")
        ))
        #expect(!FileManager.default.fileExists(atPath: capture.fileURL.path))
        #expect(try Data(contentsOf: draft.mediaURL(media)) == Data("shot.png".utf8))

        let onDisk = try fixture.bundleOnDisk("draft-a")
        #expect(onDisk == draft.bundle)
        #expect(onDisk.title == "Safari review")
        #expect(onDisk.context == CaptureContext(appName: "Safari"))
        #expect(onDisk.createdAt == Date(timeIntervalSince1970: 1000))
        #expect(onDisk.validate().isEmpty)
        #expect(try fixture.store.current() == draft)
    }

    @Test func laterCapturesAppendToTheSameDraft() throws {
        let fixture = try Fixture()
        try fixture.store.add(fixture.capture("one.png"))
        let (draft, media) = try fixture.store.add(fixture.capture("two.MOV", kind: .video, context: CaptureContext(appName: "Notes")))

        #expect(draft.directory.lastPathComponent == "draft-a")
        #expect(media.id == "m2")
        #expect(media.filename == "capture-2.mov")
        #expect(media.durationMs == 1500)
        #expect(draft.bundle.media.map(\.filename) == ["capture-1.png", "capture-2.mov"])
        // The review-level context stays the first capture's; each capture keeps its own.
        #expect(draft.bundle.context.appName == "Safari")
        #expect(draft.bundle.media.map { $0.context?.appName } == ["Safari", "Notes"])
        #expect(try fixture.bundleOnDisk("draft-a").media.count == 2)
    }

    /// A recording's audio track lands in review.json as `hasAudio: true`; images never carry it.
    @Test func audioIsRecordedForVideosOnly() throws {
        let fixture = try Fixture()
        var video = try fixture.capture("talk.mov", kind: .video)
        video.hasAudio = true
        var image = try fixture.capture("still.png")
        image.hasAudio = true
        let silent = try fixture.capture("quiet.mov", kind: .video)
        try fixture.store.add(video)
        try fixture.store.add(image)
        try fixture.store.add(silent)
        #expect(try fixture.bundleOnDisk("draft-a").media.map(\.hasAudio) == [true, nil, nil])
    }

    @Test func startNewBeginsAFreshDraftAndKeepsTheOldOne() throws {
        let fixture = try Fixture()
        try fixture.store.add(fixture.capture("one.png"))
        try fixture.store.startNew()
        #expect(try fixture.store.current() == nil)

        let (draft, media) = try fixture.store.add(fixture.capture("two.png"))
        #expect(draft.directory.lastPathComponent == "draft-b")
        #expect(media.filename == "capture-1.png")
        #expect(try fixture.bundleOnDisk("draft-a").media.count == 1)

        // start-new twice in a row, then refill.
        try fixture.store.startNew()
        try fixture.store.startNew()
        #expect(try fixture.store.add(fixture.capture("three.png")).draft.directory.lastPathComponent == "draft-c")
    }

    @Test func aStalePointerStartsANewDraft() throws {
        let fixture = try Fixture()
        let first = try fixture.store.add(fixture.capture()).draft
        try FileManager.default.removeItem(at: first.directory)
        #expect(try fixture.store.current() == nil)
        #expect(try fixture.store.add(fixture.capture("again.png")).draft.directory.lastPathComponent == "draft-b")
    }

    @Test func pointerCannotEscapeTheRoot() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data("../scratch".utf8).write(to: fixture.root.appendingPathComponent("current"))
        #expect(try fixture.store.current() == nil)
    }

    @Test func aCorruptDraftFailsWithoutLosingTheCapture() throws {
        let fixture = try Fixture()
        let draft = try fixture.store.add(fixture.capture()).draft
        try Data("{not json".utf8).write(to: draft.bundleURL)
        let capture = try fixture.capture("next.png")
        #expect(throws: ReviewDraftError.unreadableDraft(draft.bundleURL)) { try fixture.store.add(capture) }
        #expect(FileManager.default.fileExists(atPath: capture.fileURL.path))
    }

    @Test func aMissingCaptureFileChangesNothing() throws {
        let fixture = try Fixture()
        var capture = try fixture.capture()
        capture.fileURL = fixture.scratch.appendingPathComponent("gone.png")
        #expect(throws: ReviewDraftError.missingCaptureFile(capture.fileURL)) { try fixture.store.add(capture) }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test func skipsFilenamesAlreadyOnDisk() throws {
        let fixture = try Fixture()
        let draft = try fixture.store.add(fixture.capture()).draft
        try Data().write(to: draft.directory.appendingPathComponent("capture-2.png"))
        #expect(try fixture.store.add(fixture.capture("b.png")).media.filename == "capture-3.png")
    }

    @Test func emptyContextIsNotStoredPerMedia() throws {
        let fixture = try Fixture()
        let (draft, media) = try fixture.store.add(fixture.capture(context: CaptureContext()))
        #expect(media.context == nil)
        #expect(draft.bundle.title == "UX review")
    }

    // New Review (⌘N): an empty draft becomes current, and later captures go into it.
    @Test func createEmptyDraftBecomesCurrentAndTakesTheNextCapture() throws {
        let fixture = try Fixture()
        let empty = try fixture.store.createEmptyDraft()
        #expect(empty.bundle.media.isEmpty)
        #expect(empty.bundle.title == "UX review")
        #expect(try fixture.store.current()?.directory == empty.directory)
        #expect(try fixture.bundleOnDisk("draft-a").media.isEmpty)
        let (draft, media) = try fixture.store.add(fixture.capture())
        #expect(draft.directory == empty.directory)
        #expect(media.filename == "capture-1.png")
        // The first capture's context fills the empty draft's.
        #expect(draft.bundle.context.appName == "Safari")
    }

    @Test func createEmptyDraftSetsTheCurrentOneAside() throws {
        let fixture = try Fixture()
        let first = try fixture.store.add(fixture.capture()).draft
        let empty = try fixture.store.createEmptyDraft()
        #expect(empty.directory != first.directory)
        #expect(try fixture.store.current()?.directory == empty.directory)
        #expect(try fixture.bundleOnDisk("draft-a").media.count == 1)
        // Twice in a row: two empty drafts, the newest current; then Start New ends it.
        let second = try fixture.store.createEmptyDraft()
        #expect(try fixture.store.current()?.directory == second.directory)
        #expect(try fixture.store.listDrafts().count == 3)
        try fixture.store.startNew()
        #expect(try fixture.store.current() == nil)
        #expect(try fixture.store.add(fixture.capture("b.png")).draft.directory != second.directory)
    }

    @Test func defaultIDsAreUniqueAndSortable() {
        let first = ReviewDraftStore.makeDraftID()
        let second = ReviewDraftStore.makeDraftID()
        #expect(first != second)
        #expect(first.count == "yyyyMMdd-HHmmss-XXXXXX".count)
        #expect(ReviewDraftStore.defaultRoot.path.hasSuffix("Application Support/UX Review/Drafts"))
    }
}
