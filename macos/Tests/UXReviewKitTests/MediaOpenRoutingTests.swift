import Foundation
import Testing
@testable import UXReviewKit

/// Routing of files opened from Finder ("Open With", the app icon) and dropped on an editor
/// window (docs/04-capture.md §4.12.1–§4.12.2).
struct MediaOpenRoutingTests {
    /// A temp folder of placeholder files. The plan never reads contents, so any bytes do.
    private func folder(_ names: [String]) throws -> URL {
        let dir = try TestSupport.makeTempDirectory()
        for name in names {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    @Test func emptyInputImportsNothing() {
        #expect(MediaOpenRouting.plan([]) == .reject(.nothingToImport))
    }

    @Test func imagesAndMoviesImportInTheOrderGiven() throws {
        let dir = try folder(["b.mov", "a.PNG", "c.jpeg", "d.MP4", "e.heic"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = ["b.mov", "a.PNG", "c.jpeg", "d.MP4", "e.heic"].map { dir.appendingPathComponent($0) }
        #expect(MediaOpenRouting.plan(urls) == .importFiles(urls))
    }

    @Test func duplicatesKeepTheFirstOccurrence() throws {
        let dir = try folder(["a.png", "b.mov"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("a.png")
        let movie = dir.appendingPathComponent("b.mov")
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        let dotted = URL(fileURLWithPath: dir.path + "/./a.png")
        #expect(MediaOpenRouting.plan([image, movie, image, dotted, link, movie]) == .importFiles([image, movie]))
        #expect(MediaOpenRouting.plan([image, image, image]) == .importFiles([image]))
    }

    @Test func oneUnsupportedFileRejectsTheWholeBatchWhereverItIs() throws {
        let dir = try folder(["a.png", "notes.txt", "b.mov", "README"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("a.png")
        let movie = dir.appendingPathComponent("b.mov")
        let text = dir.appendingPathComponent("notes.txt")
        let bare = dir.appendingPathComponent("README")
        #expect(MediaOpenRouting.plan([image, text, movie]) == .reject(.unsupported(text)))
        #expect(MediaOpenRouting.plan([text, image]) == .reject(.unsupported(text)))
        #expect(MediaOpenRouting.plan([image, movie, text]) == .reject(.unsupported(text)))
        #expect(MediaOpenRouting.plan([bare]) == .reject(.unsupported(bare))) // no extension, no type
    }

    @Test func missingFilesAndFoldersAreRejected() throws {
        let dir = try folder(["a.png"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("a.png")
        let gone = dir.appendingPathComponent("gone.mov")
        // A folder is unsupported even when its name looks like media.
        let shots = dir.appendingPathComponent("shots.png", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: false)
        #expect(MediaOpenRouting.plan([image, gone]) == .reject(.missing(gone)))
        #expect(MediaOpenRouting.plan([shots]) == .reject(.unsupported(shots.standardizedFileURL)))
        #expect(MediaOpenRouting.plan([dir]) == .reject(.unsupported(dir.standardizedFileURL)))
        // The first problem in the order given is the one reported.
        #expect(MediaOpenRouting.plan([gone, shots]) == .reject(.missing(gone)))
        #expect(MediaOpenRouting.plan([shots, gone]) == .reject(.unsupported(shots.standardizedFileURL)))
        // A file deleted between drops is caught on the next plan.
        #expect(MediaOpenRouting.plan([image]) == .importFiles([image]))
        try FileManager.default.removeItem(at: image)
        #expect(MediaOpenRouting.plan([image]) == .reject(.missing(image)))
    }

    @Test func nonFileURLsAreRejected() throws {
        let web = try #require(URL(string: "https://example.com/shot.png"))
        #expect(MediaOpenRouting.plan([web]) == .reject(.unsupported(web)))
    }

    // MARK: Import through the plan

    private func png(_ url: URL) throws {
        try ImageFiles.writePNG(#require(ImageFiles.testCard(width: 40, height: 30)), to: url)
    }

    @Test func openWithGoesIntoTheCurrentDraftWithDuplicatesRemoved() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("a.png")
        try png(image)
        let store = ReviewDraftStore(root: dir.appendingPathComponent("drafts"))
        let (draft, media) = try await MediaOpenRouting.open([image, image], into: store)
        #expect(media.map(\.id) == ["m1"])
        #expect(try store.current()?.directory == draft.directory)
        let (again, more) = try await MediaOpenRouting.open([image], into: store)
        #expect(again.directory == draft.directory && more.map(\.id) == ["m2"]) // appended to the same current draft
    }

    @Test func aDropGoesIntoTheEditorsDraftAndLeavesTheCurrentDraftAlone() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("a.png")
        try png(image)
        let store = ReviewDraftStore(root: dir.appendingPathComponent("drafts"))
        let older = try await MediaOpenRouting.open([image], into: store).draft
        let newer = try await MediaImporter.importFiles([image], into: store, newReview: true).draft
        #expect(older.directory != newer.directory)

        let (target, media) = try await MediaOpenRouting.open([image], into: store, draft: older.directory)
        #expect(target.directory == older.directory)
        #expect(media.map(\.filename) == ["capture-2.png"])
        #expect(try store.load(older.directory).bundle.media.count == 2)
        #expect(try store.load(newer.directory).bundle.media.count == 1)
        #expect(try store.current()?.directory == newer.directory) // still current

        // newReview is ignored when a draft is named: the current draft is not ended.
        _ = try await MediaImporter.importFiles([image], into: store, draft: older.directory, newReview: true)
        #expect(try store.current()?.directory == newer.directory)
    }

    @Test func aRejectedOrFailedDropChangesNothing() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("a.png")
        try png(image)
        let text = dir.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: text)
        let store = ReviewDraftStore(root: dir.appendingPathComponent("drafts"))
        let draft = try await MediaOpenRouting.open([image], into: store).draft

        await #expect(throws: MediaImportError.unsupported(text)) {
            try await MediaOpenRouting.open([image, text], into: store, draft: draft.directory)
        }
        await #expect(throws: MediaImportError.nothingToImport) { try await MediaOpenRouting.open([], into: store) }
        // The editor's draft was deleted out from under it: an error, and no new draft appears.
        let gone = dir.appendingPathComponent("drafts/deleted", isDirectory: true)
        await #expect(throws: ReviewDraftError.self) { try await MediaOpenRouting.open([image], into: store, draft: gone) }
        #expect(try store.load(draft.directory).bundle.media.count == 1)
        #expect(try store.current()?.directory == draft.directory)
        let drafts = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("drafts").path)
        #expect(drafts.filter { $0 != ReviewDraftStore.currentPointerFilename }.count == 1)
    }
}

/// Coalescing of URLs that Launch Services delivers in several `application(_:open:)` calls.
struct OpenBatchTests {
    @Test func collectsUntilFlushedAndRestartsAfterwards() {
        var batch = OpenBatch()
        let image = URL(fileURLWithPath: "/a.png")
        let movie = URL(fileURLWithPath: "/b.mov")
        var started: [Bool] = []
        started.append(batch.add([])) // nothing to schedule
        #expect(batch.flush().isEmpty) // flushing an empty batch is harmless
        started.append(batch.add([image])) // starts a batch: schedule a flush
        started.append(batch.add([movie, image])) // joins it
        started.append(batch.add([]))
        #expect(started == [false, true, false, false])
        #expect(batch.flush() == [image, movie, image]) // duplicates are the plan's job
        #expect(batch.flush().isEmpty)
        let restarted = batch.add([movie]) // empty then refill starts a new batch
        #expect(restarted)
        #expect(batch.pending == [movie])
    }
}

struct OpenMediaCommandTests {
    @Test func parsesFilesAndOptions() throws {
        #expect(try OpenMediaCommand.parse(["--import", "a.png"]) == nil)
        let command = try #require(try OpenMediaCommand.parse([
            "--open-media", "a.png", "/abs/b.mov", "--drafts-dir", "/tmp/drafts", "--into-draft", "/tmp/drafts/d1",
        ]))
        #expect(command.files.map(\.lastPathComponent) == ["a.png", "b.mov"])
        #expect(command.draftsDirectory?.path == "/tmp/drafts")
        #expect(command.intoDraft?.path == "/tmp/drafts/d1")
        #expect(try OpenMediaCommand.parse(["--open-media", "x.png"]) == OpenMediaCommand(files: [URL(fileURLWithPath: "x.png")]))
    }

    @Test func needsAtLeastOneFileAndAValueForEachOption() {
        #expect(throws: CommandLineError.missingValue("--open-media")) { try OpenMediaCommand.parse(["--open-media"]) }
        #expect(throws: CommandLineError.missingValue("--open-media")) { try OpenMediaCommand.parse(["--open-media", "--into-draft", "d"]) }
        #expect(throws: CommandLineError.self) { try OpenMediaCommand.parse(["--open-media", "a.png", "--into-draft"]) }
    }
}
