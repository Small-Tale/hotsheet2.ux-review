import CoreMedia
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import UXReviewKit

extension EncodingTests {

    struct MediaImporterTests {
        private func writeImage(_ image: CGImage, to url: URL, type: UTType, orientation: Int? = nil) throws {
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
            CGImageDestinationAddImage(destination, image, properties)
            #expect(CGImageDestinationFinalize(destination))
        }

        private func writeMovie(to url: URL, width: Int = 160, height: Int = 90) async throws {
            let writer = try VideoFileWriter(url: url, width: width, height: height, framesPerSecond: 10)
            let card = try #require(ImageFiles.testCard(width: width, height: height))
            let frame = try #require(VideoFileWriter.pixelBuffer(from: card, width: width, height: height))
            for index in 0 ..< 5 {
                let time = CMTime(value: CMTimeValue(index * 60), timescale: 600)
                while !writer.append(frame, at: time) {
                    try await Task.sleep(for: .milliseconds(5))
                    if writer.framesDropped > 500 { Issue.record("encoder never became ready"); return }
                }
            }
            _ = try await writer.finish(at: CMTime(seconds: 1, preferredTimescale: 600))
        }

        @Test func copiesAPNGIntoANewDraftAndLeavesTheSourceAlone() async throws {
            let dir = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = dir.appendingPathComponent("Screenshot 2026-10-01.png")
            try writeImage(#require(ImageFiles.testCard(width: 120, height: 80)), to: source, type: .png)
            let store = ReviewDraftStore(root: dir.appendingPathComponent("drafts"))

            let (draft, media) = try await MediaImporter.importFiles([source], into: store)
            #expect(media.count == 1)
            #expect(media[0].kind == .image)
            #expect(media[0].filename == "capture-1.png")
            #expect(media[0].pixelWidth == 120 && media[0].pixelHeight == 80)
            #expect(media[0].context == nil) // nothing is known about where it came from
            #expect(FileManager.default.fileExists(atPath: source.path)) // copied, not moved
            #expect(try ImageFiles.pixelSize(of: draft.mediaURL(media[0])) == (120, 80))
            #expect(try store.current()?.bundle.media.map(\.filename) == ["capture-1.png"]) // written to review.json
        }

        /// A JPEG stored landscape with EXIF orientation 6 (rotate 90° clockwise) is shown portrait
        /// everywhere else, so it must arrive upright as a portrait PNG.
        @Test func appliesEXIFOrientationAndReencodesToPNG() async throws {
            let dir = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = dir.appendingPathComponent("photo.JPG")
            try writeImage(#require(ImageFiles.testCard(width: 40, height: 20)), to: source, type: .jpeg, orientation: 6)
            let store = ReviewDraftStore(root: dir.appendingPathComponent("drafts"))

            let (draft, media) = try await MediaImporter.importFiles([source], into: store)
            #expect(media[0].filename == "capture-1.png")
            #expect(media[0].pixelWidth == 20 && media[0].pixelHeight == 40)
            let url = draft.mediaURL(media[0])
            let type = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(CGImageSourceGetType))
            #expect(type as String == UTType.png.identifier)
            #expect(try ImageFiles.pixelSize(of: url) == (20, 40))
        }

        @Test(.timeLimit(.minutes(1)))
        func copiesAMovieWithItsSizeAndDuration() async throws {
            let dir = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = dir.appendingPathComponent("old-recording.MOV")
            try await writeMovie(to: source)
            let store = ReviewDraftStore(root: dir.appendingPathComponent("drafts"))

            let (draft, media) = try await MediaImporter.importFiles([source], into: store)
            #expect(media[0].kind == .video)
            #expect(media[0].filename == "capture-1.mov")
            #expect(media[0].pixelWidth == 160 && media[0].pixelHeight == 90)
            #expect(abs((media[0].durationMs ?? 0) - 1000) <= 50)
            #expect(media[0].hasAudio == nil) // no audio track
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(try Data(contentsOf: draft.mediaURL(media[0])) == Data(contentsOf: source)) // byte-for-byte copy
        }

        @Test func appendsToTheCurrentDraftInOrder() async throws {
            let dir = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = ReviewDraftStore(root: dir.appendingPathComponent("drafts"))
            let first = dir.appendingPathComponent("a.png")
            let second = dir.appendingPathComponent("b.png")
            let card = try #require(ImageFiles.testCard(width: 10, height: 10))
            try writeImage(card, to: first, type: .png)
            try writeImage(card, to: second, type: .png)
            let existing = try await MediaImporter.importFiles([first], into: store)

            let (draft, media) = try await MediaImporter.importFiles([second, first], into: store)
            #expect(draft.directory == existing.draft.directory)
            #expect(media.map(\.filename) == ["capture-2.png", "capture-3.png"])
            #expect(media.map(\.id) == ["m2", "m3"])
            #expect(draft.bundle.media.count == 3)
        }

        /// Everything is prepared before anything is added: one bad file leaves no trace.
        @Test func oneBadFileImportsNothing() async throws {
            let dir = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = ReviewDraftStore(root: dir.appendingPathComponent("drafts"))
            let good = dir.appendingPathComponent("good.png")
            try writeImage(#require(ImageFiles.testCard(width: 10, height: 10)), to: good, type: .png)
            let text = dir.appendingPathComponent("notes.txt")
            try Data("hello".utf8).write(to: text)
            let corrupt = dir.appendingPathComponent("broken.png")
            try Data("not a png".utf8).write(to: corrupt)
            let fakeMovie = dir.appendingPathComponent("broken.mov")
            try Data("not a movie".utf8).write(to: fakeMovie)
            let missing = dir.appendingPathComponent("gone.png")

            let cases: [([URL], MediaImportError)] = [
                ([good, text], .unsupported(text)),
                ([good, corrupt], .unreadable(corrupt)),
                ([fakeMovie], .unreadable(fakeMovie)),
                ([good, missing], .missing(missing)),
                ([], .nothingToImport),
            ]
            for (files, expected) in cases {
                await #expect(throws: expected) { try await MediaImporter.importFiles(files, into: store) }
            }
            #expect(try store.current() == nil)
            #expect(!FileManager.default.fileExists(atPath: store.root.path)) // no draft was even created

            // A failed import that asked for a new review keeps the current one current.
            let current = try await MediaImporter.importFiles([good], into: store)
            await #expect(throws: MediaImportError.unsupported(text)) {
                try await MediaImporter.importFiles([good, text], into: store, newReview: true)
            }
            #expect(try store.current()?.directory == current.draft.directory)
            let fresh = try await MediaImporter.importFiles([good], into: store, newReview: true)
            #expect(fresh.draft.directory != current.draft.directory)
            #expect(fresh.media.map(\.filename) == ["capture-1.png"])
        }

        @Test func errorsExplainThemselves() {
            let url = URL(fileURLWithPath: "/tmp/notes.txt")
            #expect(MediaImportError.unsupported(url).description == "notes.txt isn't an image or a movie.")
            #expect(MediaImportError.unsupported(url).code == "unsupportedMedia")
            #expect(MediaImportError.unreadable(url).code == "unreadableMedia")
            #expect(MediaImportError.missing(url).code == "missingFile")
            #expect(MediaImportError.nothingToImport.code == "nothingToImport")
        }
    }

    struct ImportCommandTests {
        @Test func parsesFilesAndOptions() throws {
            #expect(try ImportCommand.parse(["--status"]) == nil)
            let command = try #require(try ImportCommand.parse([
                "--import", "a.png", "/abs/b.mov", "--drafts-dir", "/tmp/drafts", "--new-review",
            ]))
            #expect(command.files.map(\.lastPathComponent) == ["a.png", "b.mov"])
            #expect(command.files[1].path == "/abs/b.mov")
            #expect(command.draftsDirectory?.path == "/tmp/drafts")
            #expect(command.newReview)
            let plain = try #require(try ImportCommand.parse(["--import", "x.png"]))
            #expect(plain == ImportCommand(files: [URL(fileURLWithPath: "x.png")]))
        }

        @Test func needsAtLeastOneFile() {
            #expect(throws: CommandLineError.missingValue("--import")) { try ImportCommand.parse(["--import"]) }
            #expect(throws: CommandLineError.missingValue("--import")) { try ImportCommand.parse(["--import", "--new-review"]) }
        }
    }
}
